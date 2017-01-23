use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use BibSpace;
use BibSpace::Controller::Core;

my $t_logged_in = Test::Mojo->new('BibSpace');
$t_logged_in->post_ok(
    '/do_login' => { Accept => '*/*' },
    form        => { user   => 'pub_admin', pass => 'asdf' }
);
my $self = $t_logged_in->app;

$t_logged_in->ua->max_redirects(10);
$t_anyone->ua->max_redirects(10);
$t_anyone->ua->inactivity_timeout(3600);
my $dbh = $t_logged_in->app->db;

use BibSpace::Functions::FPublications;
use BibSpace::Controller::Core;

####################################################################
subtest 'PublicationsSEO: public functions' => sub {

    my @entries   = $self->app->repo->getEntriesRepository->all;
    my $main_SEOpage = $self->url_for('metalist_all_entries');
    $t_anyone->get_ok($main_SEOpage)
        ->status_isnt( 404, "Checking: 404 $main_SEOpage" )
        ->status_isnt( 500, "Checking: 500 $main_SEOpage" );

    for my $e (@entries) {
        note
            "============ Testing SEO page for entry id $e->{id} ============";
        my $entry_id = $e->id;
        my $page = $self->url_for( 'metalist_entry', id => $entry_id );

        if ( !$e->is_hidden() ) {
            $t_anyone->get_ok($page)
                ->status_isnt( 404, "HIDDEN==FALSE Checking: 404 $page" )
                ->status_isnt( 500, "Checking: 500 $page" )
                ->status_isnt( 503, "Checking: 503 $page" );
        }
        else {
            $t_anyone->get_ok($page)
                ->status_is( 404, "HIDDEN==TRUE Checking: 404 $page" );
            my $str_that_should_not_be
                = "<li>Paper with id $entry_id: <a href";
            $t_anyone->get_ok($main_SEOpage)->status_is(200)
                ->content_unlike(qr/$str_that_should_not_be/i)
                ;    ### this is slow!!!

        }

    }
};

####################################################################
# TODO: {
#     local $TODO
#         = "PublicationsSEO: public functions – decoding is still not 100% ready";

#     my $main_page = $self->url_for('metalist_all_entries');
#     $t_anyone->get_ok($main_page)->status_is(200)->content_unlike(qr/\{/i);
# }

done_testing();
