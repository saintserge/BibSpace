package BibSpace v0.6.0;

# ABSTRACT: BibSpace is a system to manage Bibtex references for authors and research groups web page.

use BibSpace::Functions::Core;
use BibSpace::Functions::MySqlBackupFunctions;
use BibSpace::Functions::FDB;
use BibSpace::Functions::FPublications;

# on test server:
# BIBSPACE_CONFIG=/etc/bibspace_test.conf BIBSPACE_USE_DUMP=0 MOJO_MODE=development hypnotoad bin/bibspace

use Mojo::Base 'Mojolicious';
use Mojo::Base 'Mojolicious::Plugin::Config';

use Data::Dumper;

use POSIX qw/strftime/;
use Try::Tiny;
use Path::Tiny;    # for creating directories
use Mojo::Home;
use File::Spec;

use BibSpace::Util::SimpleLogger;
use BibSpace::Util::Statistics;

use BibSpace::Model::User;

use BibSpace::DAO::DAOFactory;

use BibSpace::Repository::FlatRepository;
use BibSpace::Repository::RepositoryLayer;
use BibSpace::Repository::FlatRepositoryFacade;

use BibSpace::Converter::IHtmlBibtexConverter;
use BibSpace::Converter::Bibtex2HtmlConverter;
use BibSpace::Converter::BibStyleConverter;

use BibSpace::Util::Preferences;
use BibSpace::Util::EntityFactory;

# STATE keyword
# state declares a lexically scoped variable, just like my.
# However, those variables will never be reinitialized,
# contrary to lexical variables that are reinitialized each time their enclosing block is entered.
# See Persistent Private Variables in perlsub for details.
use feature qw( state say );

## OBJECTS CREATED AND CONTAINED IN HAS METHODS CANNOT BE CHANGED AT RUNTIME!

has preferences => sub {
  my $self = shift;
  my $file = $self->app->home->rel_file("json_data/bibspace_preferences.json");
  return state $prefs = Preferences->new(filename => "" . $file)->load_maybe;
};

has statistics => sub {
  my $self = shift;
  my $file = $self->app->home->rel_file("json_data/bibspace_stats.json");
  say $file;
  return state $stats = Statistics->new(filename => "" . $file)->load_maybe;
};

has config_file => sub {
  my $self = shift;
  my $candidate;
  $candidate = $ENV{BIBSPACE_CONFIG};
  return $candidate if defined $candidate and -e $candidate;

  $candidate = $self->app->home->rel_file('/etc/bibspace.conf');
  return $candidate if -e $candidate;

  $candidate
    = $self->app->home->rel_file('lib/BibSpace/files/config/default.conf');
  return $candidate if -e $candidate;

  $candidate = $self->app->home->rel_file('config/default.conf');   # for travis
  return $candidate if -e $candidate;

  die "Cannot find Bibspace config!";
};

has get_backups_dir => sub {
  my $self        = shift;
  my $backups_dir = $self->app->config->{backups_dir};
  $backups_dir =~ s!/*$!/!;
  return $backups_dir;
};

has get_upload_dir => sub {
  my $c          = shift;
  my $upload_dir = $c->app->config->{upload_dir};
  $upload_dir =~ s!/*$!/!;
  return $upload_dir;
};

has get_log_dir => sub {
  my $c       = shift;
  my $log_dir = $c->app->config->{log_dir};
  $log_dir =~ s!/*$!/!;
  return $log_dir;
};

# do not use this - if MySQL server dies during operation, you will be not able to reconnect!
# use helper
## OBJECTS CREATED AND CONTAINED IN HAS METHODS CANNOT BE CHANGED AT RUNTIME!
# has db => sub {
#     my $self = shift;
#     state $db = db_connect(
#         $self->config->{db_host},     $self->config->{db_user},
#         $self->config->{db_database}, $self->config->{db_pass}
#     );
# };

has version => sub {
  return $BibSpace::VERSION // "0.6.0";
};

# Using multiple is not be supported currently.
# Use only stateless loggers.
has logger => sub { state $logger = SimpleLogger->new() };

## I moved this to helpers as app->attr for a while

has flatRepository => sub {
  my $self = shift;
  $self->app->logger->info("Building flatRepository");

  my $mySQLLayer = RepositoryLayer->new(
    name                          => 'mysql',
    priority                      => 99,
    creates_on_read               => 1,
    backendFactoryName            => "MySQLDAOFactory",
    logger                        => $self->logger,
    handle                        => $self->db,
    reset_data_callback           => \&reset_db_data,
    reset_data_callback_arguments => [$self->db],
  );

  return FlatRepository->new(
    logger      => $self->logger,
    preferences => $self->preferences,
    layer       => $mySQLLayer
  );
};

has repo => sub {
  my $self = shift;
  return FlatRepositoryFacade->new(lr => $self->flatRepository);
};

sub startup {
  my $self = shift;
  $self->app->logger->info("*** Starting BibSpace ***");
  $self->setup_config;
  $self->setup_plugins;
  create_main_db($self->app->db);

  $self->app->preferences->local_time_zone(
    DateTime::TimeZone->new(name => 'local')->name);

  $self->setup_routes;
  $self->setup_hooks;
  $self->insert_admin;

  $self->app->logger->info("Setup done.");

  $self->app->logger->info("Using CONFIG: " . $self->app->config_file);
  $self->app->logger->info("App home is: " . $self->app->home);
  $self->app->logger->info("Active bst file is: " . $self->app->bst);

  return;
}

sub insert_admin {
  my $self = shift;
  $self->app->logger->info("Add startup admin user...");

  my $admin_exists
    = $self->app->repo->users_find(sub { $_->login eq 'pub_admin' });
  if (!$admin_exists) {
    my $salt     = salt();
    my $hash     = encrypt_password('asdf', $salt);
    my $new_user = $self->app->entityFactory->new_User(
      login     => 'pub_admin',
      email     => 'pub_admin@example.com',
      real_name => 'Admin',
      rank      => 99,
      pass      => $hash,
      pass2     => $salt
    );
    $self->app->repo->users_save($new_user);
  }
  else {
    # this email is used in tests!
    $admin_exists->email('pub_admin@example.com');
    $admin_exists->make_admin;
    $self->app->repo->users_update($admin_exists);
  }
  return;
}

sub setup_config {
  my $self = shift;
  my $app  = $self;
  $self->app->logger->info("Setup config...");
  $self->plugin('Config' => {file => $self->app->config_file});

  $ENV{MOJO_MAX_MESSAGE_SIZE} = 40 * 1024 * 1024;
  $self->app->logger->info(
    "Setting max upload size to " . $ENV{MOJO_MAX_MESSAGE_SIZE} . " Bytes.");
  return;
}

sub setup_plugins {
  my $self = shift;
  $self->app->logger->info("Setup plugins...");

  $ENV{MOJO_REVERSE_PROXY} = 1;

  $self->app->plugin('InstallablePaths');
  $self->app->plugin('RenderFile');
  $self->plugin('BibSpace::Controller::Helpers');

  push @{$self->app->static->paths}, $self->app->home->rel_file('public');

  # push @{$self->app->static->paths}, $self->config->{backups_dir};

  $self->app->logger->info("App version: " . $self->app->version);
  $self->app->logger->info("Creating directories...");
  for my $dir (
    (
      $self->app->get_backups_dir,
      $self->app->get_upload_dir,
      $self->app->get_upload_dir . "papers",
      $self->app->get_upload_dir . "slides",
      $self->app->get_log_dir
    )
    )
  {
    $self->app->logger->debug("Creating directory: $dir");
    try {
      Path::Tiny->new($dir)->mkpath;
    }
    catch {
      $self->app->logger->error(
        "Exception: cannot create directory $dir. Msg: $_");
    };
  }

  # set logging dir in the logger
  $self->app->logger->debug("Setting log dir to the logger");
  $self->logger->set_log_dir("" . Path::Tiny->new($self->get_log_dir));

  # this is supposed to trigger connection to the DB
  $self->app->db;
  $self->secrets([$self->config->{key_cookie}]);
  $self->helper(proxy_prefix => sub { $self->config->{proxy_prefix} });
  return;
}

sub setup_routes {
  my $self = shift;
  $self->app->logger->info("Setup routes...");

  my $anyone = $self->routes;
  $anyone->get('/')->to('display#index')->name('start');

  $anyone->get('/forgot')->to('login#forgot')->name('forgot_password');
  $anyone->post('/forgot/gen')->to('login#post_gen_forgot_token');
  $anyone->get('/forgot/reset/<:token>')->to('login#token_clicked')
    ->name("token_clicked");
  $anyone->post('/forgot/store')->to('login#store_password');

  $anyone->get('/login_form')->to('login#login_form')->name('login_form');
  $anyone->post('/do_login')->to('login#login')->name('do_login');
  $anyone->get('/youneedtologin')->to('login#not_logged_in')
    ->name('youneedtologin');
  $anyone->get('/badpassword')->to('login#bad_password')->name('badpassword');

  $anyone->get('/logout')->to('login#logout')->name('logout');

  $anyone->any('/test/500')->to('display#test500')->name('error500');
  $anyone->any('/test/404')->to('display#test404')->name('error404');

  $anyone->get('/register')->to('login#register')->name('register');
  $anyone->post('/register')->to('login#post_do_register')
    ->name('post_do_register');
  $anyone->any('/noregister')->to('login#register_disabled')
    ->name('registration_disabled');

  my $logged_user  = $anyone->under->to('login#check_is_logged_in');
  my $manager_user = $logged_user->under->to('login#under_check_is_manager');
  my $admin_user   = $logged_user->under->to('login#under_check_is_admin');

  ################ PREFERENCES ################

  $manager_user->get('/preferences')->to('preferences#index')
    ->name('preferences');
  $admin_user->post('/preferences')->to('preferences#save')
    ->name('save_preferences');

  ################ EXPERIMENTAL / PERSISTENCE ################

  $anyone->get('/system_status')->to('persistence#system_status')
    ->name('system_status');
  $admin_user->get('/persistence/load')->to('persistence#load_fixture')
    ->name('load_fixture');
  $admin_user->get('/persistence/save')->to('persistence#save_fixture')
    ->name('save_fixture');

  $admin_user->get('/persistence/persistence_status_ajax')
    ->to('persistence#persistence_status_ajax')
    ->name('persistence_status_ajax');

  $admin_user->get('/persistence/reset_mysql')->to('persistence#reset_mysql')
    ->name('reset_mysql');
  $admin_user->get('/persistence/reset_smart')->to('persistence#reset_smart')
    ->name('reset_smart');
  $admin_user->get('/persistence/reset_all')->to('persistence#reset_all')
    ->name('reset_all');

  ################ SETTINGS ################
  $logged_user->get('/profile')->to('login#profile')->name('show_my_profile');
  $admin_user->get('/manage_users')->to('login#manage_users')
    ->name('manage_users');
  $admin_user->get('/profile/<:id>')->to('login#foreign_profile')
    ->name('show_user_profile');
  $admin_user->get('/profile/delete/<:id>')->to('login#delete_user')
    ->name('delete_user');

  $admin_user->get('/profile/make_user/<:id>')->to('login#make_user')
    ->name('make_user');
  $admin_user->get('/profile/make_manager/<:id>')->to('login#make_manager')
    ->name('make_manager');
  $admin_user->get('/profile/make_admin/<:id>')->to('login#make_admin')
    ->name('make_admin');

  $manager_user->get('/log')->to('display#show_log')->name('show_log');
  $manager_user->get('/statistics')->to('display#show_stats')
    ->name('show_stats');

  # websocket for fun
  $manager_user->websocket('/log_websocket/<:num>')->to('display#show_log_ws')
    ->name('show_log_websocket');
  $manager_user->websocket('/statistics/<:num>')
    ->to('display#show_stats_websocket')->name('show_stats_websocket');

  $admin_user->get('/settings/fix_months')->to('publications#fixMonths')
    ->name('fix_all_months');

  $manager_user->get('/settings/clean_all')
    ->to('publications#clean_ugly_bibtex')->name('clean_ugly_bibtex');

  $manager_user->get('/settings/mark_all_to_regenerate')
    ->to('publications#mark_all_to_regenerate')->name('mark_all_to_regenerate');

  $manager_user->get('/settings/mark_author_to_regenerate/<:author_id>')
    ->to('publications#mark_author_to_regenerate')
    ->name('mark_author_to_regenerate');

  $manager_user->get('/settings/regenerate_all')
    ->to('publications#regenerate_html_for_all')
    ->name('regenerate_html_for_all');

  $logged_user->get('/settings/regenerate_html_in_chunk/<:chunk_size>')
    ->to('publications#regenerate_html_in_chunk')
    ->name('regenerate_html_in_chunk');

  $manager_user->get('/backups')->to('backup#index')->name('backup_index');

  # Do default backup
  $manager_user->put('/backups')->to('backup#save')->name('backup_do');
  $manager_user->put('/backups/mysql')->to('backup#save_mysql')
    ->name('backup_do_mysql');
  $manager_user->put('/backups/json')->to('backup#save_json')
    ->name('backup_do_json');
  $manager_user->get('/backups/<:id>')->to('backup#backup_download')
    ->name('backup_download');

  $admin_user->delete('/backups/<:id>')->to('backup#delete_backup')
    ->name('backup_delete');
  $admin_user->put('/backups/<:id>')->to('backup#restore_backup')
    ->name('backup_restore');
  $admin_user->delete('/backups')->to('backup#cleanup')->name('backup_cleanup');

  ################ TYPES ################
  $logged_user->get('/types')->to('types#all_our')->name('all_types');
  $manager_user->get('/types/add')->to('types#add_type')->name('add_type_get');
  $manager_user->post('/types/add')->to('types#post_add_type')
    ->name('add_type_post');
  $manager_user->get('/types/manage/<:name>')->to('types#manage')
    ->name('edit_type');
  $manager_user->get('/types/delete/<:name>')->to('types#delete_type')
    ->name('delete_type');

  $manager_user->post('/types/store_description')
    ->to('types#post_store_description')->name('update_type_description');
  $manager_user->get('/types/toggle/<:name>')->to('types#toggle_landing')
    ->name('toggle_landing_type');

  $manager_user->get('/types/<:our_type>/map/<:bibtex_type>')
    ->to('types#map_types')->name('map_bibtex_type');
  $manager_user->get('/types/<:our_type>/unmap/<:bibtex_type>')
    ->to('types#unmap_types')->name('unmap_bibtex_type');

  ################ AUTHORS ################

  $logged_user->get('/authors/')->to('authors#all_authors')
    ->name('all_authors');
  $manager_user->get('/authors/add')->to('authors#add_author')
    ->name('add_author');
  $manager_user->post('/authors/add/')->to('authors#add_post');

  $logged_user->get('/authors/edit/<:id>')->to('authors#edit_author')
    ->name('edit_author');
  $manager_user->post('/authors/edit/')->to('authors#edit_post')
    ->name('edit_author_post');
  $manager_user->get('/authors/delete/<:id>')->to('authors#delete_author')
    ->name('delete_author');

  $admin_user->get('/authors/delete/<:id>/force')
    ->to('authors#delete_author_force')->name('delete_author_force');

  $manager_user->post('/authors/edit_membership_dates')
    ->to('authors#post_edit_membership_dates')
    ->name('edit_author_membership_dates');

  $manager_user->get('/authors/<:id>/add_to_team/<:tid>')
    ->to('authors#add_to_team')->name('add_author_to_team');
  $manager_user->get('/authors/<:id>/remove_from_team/<:tid>')
    ->to('authors#remove_from_team')->name('remove_author_from_team');
  $manager_user->get('/authors/<:master_id>/remove_uid/<:minor_id>')
    ->to('authors#remove_uid')->name('remove_author_uid');

  $manager_user->post('/authors/merge/')->to('authors#merge_authors')
    ->name('merge_authors');

  $manager_user->get('/authors/reassign')
    ->to('authors#reassign_authors_to_entries');
  $admin_user->get('/authors/reassign_and_create')
    ->to('authors#reassign_authors_to_entries_and_create_authors');

  $manager_user->get('/authors/toggle_visibility/<:id>')
    ->to('authors#toggle_visibility')->name('toggle_author_visibility');

  ################ TAG TYPES ################
  # $logged_user->get('/tags/')->to('tags#index')->name("tags_index");
  $logged_user->get('/tagtypes')->to('tagtypes#index')->name('all_tag_types');
  $admin_user->get('/tagtypes/add')->to('tagtypes#add')->name('add_tag_type');
  $admin_user->post('/tagtypes/add')->to('tagtypes#add_post')
    ->name('add_tag_type_post');
  $admin_user->get('/tagtypes/delete/<:id>')->to('tagtypes#delete')
    ->name('delete_tag_type');
  $manager_user->any('/tagtypes/edit/<:id>')->to('tagtypes#edit')
    ->name('edit_tag_type');

  ################ TAGS ################
  $logged_user->get('/tags/<:type>')->to('tags#index', type => 1)
    ->name('all_tags');
  $admin_user->get('/tags/add/<:type>')->to('tags#add', type => 1)
    ->name('add_tag_get');
  $admin_user->post('/tags/add/<:type>')->to('tags#add_post', type => 1)
    ->name('add_tag_post');
  $logged_user->get('/tags/authors/<:id>/<:type>')
    ->to('tags#get_authors_for_tag', type => 1)->name('get_authors_for_tag');
  $admin_user->get('/tags/delete/<:id>')->to('tags#delete')->name('delete_tag');

  ### EDIT TAG FORM GOES WITH GET - WTF!?!
  # FIXME: FIX THIS
  $manager_user->get('/tags/edit/<:id>')->to('tags#edit')->name('edit_tag');

  $anyone->get('/read/authors-for-tag/<:tag_id>/<:team_id>')
    ->to('tags#get_authors_for_tag_and_team')
    ->name('get_authors_for_tag_and_team');

  #ALIAS
  $anyone->get('/r/a4t/<:tag_id>/<:team_id>')
    ->to('tags#get_authors_for_tag_and_team')
    ->name('get_authors_for_tag_and_team');

  $anyone->get('/read/authors-for-tag/<:tag_id>/<:team_id>')
    ->to('tags#get_authors_for_tag_and_team')
    ->name('get_authors_for_tag_and_team');

  #ALIAS
  $anyone->get('/r/a4t/<:tag_id>/<:team_id>')
    ->to('tags#get_authors_for_tag_and_team')
    ->name('get_authors_for_tag_and_team');

  $anyone->get('/read/tags-for-author/<:author_id>')
    ->to('tags#get_tags_for_author_read')->name('tags_for_author');

  #ALIAS
  $anyone->get('/r/t4a/<:author_id>')->to('tags#get_tags_for_author_read');

  $anyone->get('/read/tags-for-team/<:team_id>')
    ->to('tags#get_tags_for_team_read')->name('tags_for_team');

  #ALIAS
  $anyone->get('/r/t4t/<:team_id>')->to('tags#get_tags_for_team_read');

  ################ TEAMS ################
  $logged_user->get('/teams')->to('teams#show')->name('all_teams');

  $manager_user->get('/teams/edit/<:id>')->to('teams#edit')->name('edit_team');
  $manager_user->get('/teams/delete/<:id>')->to('teams#delete_team')
    ->name('delete_team');
  $manager_user->get('/teams/delete/<:id>/force')
    ->to('teams#delete_team_force')->name('delete_team_force');
  $logged_user->get('/teams/<:teamid>/unrelated_papers')
    ->to('publications#show_unrelated_to_team')
    ->name('unrelated_papers_for_team');

  $manager_user->get('/teams/add')->to('teams#add_team')->name('add_team_get');
  $manager_user->post('/teams/add/')->to('teams#add_team_post')
    ->name('add_team_post');

  ################ EDITING PUBLICATIONS ################
    #<<< no perltidy here
    # EXPERIMENTAL

    $manager_user->get('/publications/add_many')
        ->to('PublicationsExperimental#publications_add_many_get')
        ->name('add_many_publications');
    $manager_user->post('/publications/add_many')
        ->to('PublicationsExperimental#publications_add_many_post')
        ->name('add_many_publications_post');

    # EXPERIMENTAL END

    $logged_user->get('/publications')
        ->to('publications#all')
        ->name('publications');

    # works nice for all or flitering, but not for recently edited/added
    # reason: requires separate template and separate javascript code
    # $logged_user->get('/publications_ajax')
    #     ->to('publications#all_ajax')
    #     ->name('publications_ajax');

    $logged_user->get('/publications/recently_added/<:num>')
        ->to('publications#all_recently_added')
        ->name('recently_added');

    $logged_user->get('/publications/recently_modified/<:num>')
        ->to('publications#all_recently_modified')
        ->name('recently_changed');

    $logged_user->get('/publications/orphaned')
        ->to('publications#all_orphaned')->name('all_orphaned');

    $admin_user->get('/publications/orphaned/delete')
        ->to('publications#delete_orphaned')->name('delete_orphaned');


    $logged_user->get('/publications/untagged/<:tagtype>')
        ->to( 'publications#all_without_tag')
        ->name('get_untagged_publications');


    $manager_user->get('/publications/candidates_to_delete')
        ->to('publications#all_candidates_to_delete');

    $manager_user->get('/publications/missing_month')
        ->to('publications#all_with_missing_month');

    $logged_user->get('/publications/get/<:id>')
        ->to('publications#single')
        ->name('get_single_publication');

    ####### ATTACHMENTS START

    # temporary alias
    # For now, ID must be a number. Change later for UUID
    $anyone->get('/publications/download/:filetype/<id:num>.pdf')
        ->to('publications#download')
        ->name('download_publication_pdf');

    $anyone->get('/publications/download/:filetype/<id:num>')
        ->to('publications#download')
        ->name('download_publication');

    $manager_user->get('/publications/discover_attachments/<id:num>')
        ->to('publications#discover_attachments')
        ->name('discover_attachments');

    $manager_user->get('/publications/remove_attachment/:filetype/<id:num>')
        ->to('publications#remove_attachment')
        ->name('publications_remove_attachment');

    $manager_user->get('/publications/fix_urls')
        ->to('publications#fix_file_urls')
        ->name('fix_attachment_urls');

    ####### ATTACHMENTS END

    $manager_user->get('/publications/toggle_hide/<:id>')
        ->to('publications#toggle_hide')
        ->name('toggle_hide_publication');



    $manager_user->get('/publications/add')
        ->to('publications#publications_add_get')
        ->name('add_publication');

    $manager_user->post('/publications/add')
        ->to('publications#publications_add_post')
        ->name('add_publication_post');

    $manager_user->get('/publications/edit/<:id>')
        ->to('publications#publications_edit_get')
        ->name('edit_publication');

    $manager_user->post('/publications/edit/<:id>')
        ->to('publications#publications_edit_post')
        ->name('edit_publication_post');

    $manager_user->get('/publications/make_paper/<:id>')
        ->to('publications#make_paper')
        ->name('make_paper');

    $manager_user->get('/publications/make_talk/<:id>')
        ->to('publications#make_talk')
        ->name('make_talk');

    $manager_user->get('/publications/regenerate/<:id>')
        ->to('publications#regenerate_html')
        ->name('regenerate_publication');


    # change to POST or DELETE
    $manager_user->get('/publications/delete_sure/<:id>')
        ->to('publications#delete_sure')
        ->name('delete_publication_sure');

    $manager_user->get('/publications/attachments/<:id>')
        ->to('publications#add_pdf')
        ->name('manage_attachments');

    $manager_user->post('/publications/add_pdf/do/<:id>')
        ->to('publications#add_pdf_post')
        ->name('post_upload_pdf');

    $manager_user->get('/publications/manage_tags/<:id>')
        ->to('publications#manage_tags')
        ->name('manage_tags');

    # change to POST or DELETE
    $manager_user->get('/publications/<:eid>/remove_tag/<:tid>')
        ->to('publications#remove_tag')
        ->name('remove_tag_from_publication');

    # change to POST or UPDATE
    $manager_user->get('/publications/<:eid>/add_tag/<:tid>')
        ->to('publications#add_tag')
        ->name('add_tag_to_publication');

    $manager_user->get('/publications/manage_exceptions/<:id>')
        ->to('publications#manage_exceptions')
        ->name('manage_exceptions');

    # change to POST or DELETE
    $manager_user->get('/publications/<:eid>/remove_exception/<:tid>')
        ->to('publications#remove_exception')
        ->name('remove_exception_from_publication');

    # change to POST or UPDATE
    $manager_user->get('/publications/<:eid>/add_exception/<:tid>')
        ->to('publications#add_exception')
        ->name('add_exception_to_publication');

    $logged_user->get('/publications/show_authors/<:id>')
        ->to('publications#show_authors_of_entry')
        ->name('show_authors_of_entry');


  ################ OPEN ACCESS ################

  # contains meta info for every paper. Optimization for google scholar
  $anyone->get('/read/publications/meta')
    ->to('PublicationsSeo#metalist')
    ->name("metalist_all_entries");

  $anyone->get('/read/publications/meta/<:id>')
    ->to('PublicationsSeo#meta')
    ->name("metalist_entry");

  ################

  $anyone->get('/read/publications')->to('publications#all_read');
  $anyone->get('/r/publications')->to('publications#all_read');    #ALIAS
  $anyone->get('/r/p')->to('publications#all_read');               #ALIAS

  $anyone->get('/read/bibtex')->to('publications#all_bibtex')->name('readbibtex');
  $anyone->get('/r/bibtex')->to('publications#all_bibtex');        #ALIAS
  $anyone->get('/r/b')->to('publications#all_bibtex');             #ALIAS

  $anyone->get('/read/publications/get/<:id>')
    ->to('publications#single_read')
    ->name('get_single_publication_read');
  $anyone->get('/r/p/get/<:id>')
    ->to('publications#single_read');

  ######## PublicationsLanding

  $anyone->get('/landing/publications')
    ->to('PublicationsLanding#landing_types')
    ->name('landing_publications');
  $anyone->get('/l/p')
    ->to('PublicationsLanding#landing_types')
    ->name('lp');

  $anyone->get('/landing-years/publications')
    ->to('PublicationsLanding#landing_years')
    ->name('landing_years_publications');
  $anyone->get('/ly/p')
    ->to('PublicationsLanding#landing_years');    #ALIAS

  ########



  ################ CRON ################

  $anyone->get('/cron')->to('cron#index');
  $anyone->get('/cron/<#level>')->to('cron#cron');

   #>>>
  return;
}

sub setup_hooks {
  my $self = shift;
  $self->app->logger->info("Setup hooks...");

  $self->hook(
    before_dispatch => sub {
      my $c = shift;

      if ($c->req->headers->header('X-Forwarded-HTTPS')) {
        $c->req->url->base->scheme('https');
      }
      $c->app->statistics->log_url($c->req->url);

      # dirty fix for production deployment in a directory
      # config->{proxy_prefix} stores the proxy prefix, e.g., /app
      my $proxy_prefix = $self->config->{proxy_prefix};
      if ($proxy_prefix ne "") {

        # we remove the leading slash
        $proxy_prefix =~ s!^/!!;

        # and let Mojolicious add it again
        push @{$c->req->url->base->path->trailing_slash(1)}, $proxy_prefix;
      }
    }
  );
  return;
}

1;
