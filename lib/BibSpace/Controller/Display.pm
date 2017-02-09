package BibSpace::Controller::Display;

use strict;
use warnings;
use utf8;
use v5.16;    #because of ~~

# use File::Slurp;
use Try::Tiny;
use List::Util qw(first);

use Data::Dumper;


use Mojo::Base 'Mojolicious::Controller';
use BibSpace::Functions::MySqlBackupFunctions;
use BibSpace::Functions::Core;

#################################################################################
sub index {
  my $self = shift;
  if ( $self->app->is_demo ) {
    $self->session( user      => 'demouser' );
    $self->session( user_name => 'demouser' );
  }
  $self->render( template => 'display/start' );
}
#################################################################################
sub test500 {
  my $self = shift;
  $self->render( text => 'Oops 500.', status => 500 );
}
#################################################################################
sub test404 {
  my $self = shift;
  $self->render( text => 'Oops 404.', status => 404 );
}
#################################################################################
sub get_log_lines {
  my $dir       = shift;
  my $num       = shift;
  my $type      = shift;
  my $filter_re = shift;


  my $log_dir = Path::Tiny->new( $dir );

  my @file_list = $log_dir->children(qr/\.log$/);
  my @log_names = map { $_->basename('.log') } @file_list;

  my $log_2_read;
  $log_2_read = $log_dir->child( $type . ".log" ) if defined $type;
  $log_2_read = $file_list[0] if !$log_2_read or !$log_2_read->exists;

  die "No log file found " if !-e $log_2_read; # throw

  # my @lines = $log_2_read->lines( { count => -1 * $num } );
  # @lines = ( $num >= @lines ) ? reverse @lines : reverse @lines[ -$num .. -1 ];
  my @lines = $log_2_read->lines();
  # @lines = reverse @lines;
  chomp(@lines);

  if( $filter_re ){
    @lines = grep{ m/$filter_re/ } @lines;    
  }
  return @lines[-$num..-1];
}
#################################################################################
sub show_log {
  my $self = shift;
  my $num  = $self->param('num') // 100;
  my $type = $self->param('type') // 'general';    # default
  my $filter = $self->param('filter');
  my $use_ajax = $self->param('ajax');


  my @lines;
  try{
    @lines = get_log_lines( $self->app->config->{log_dir}, $num, $type, $filter );
  }
  catch{
    $self->app->logger->error("Cannot find log '$type'. Error: $_.");
    $self->stash( msg_type => 'danger', msg => "Cannot find log '$type'." );
  };

  my @file_list = Path::Tiny->new( $self->app->config->{log_dir} )->children(qr/\.log$/);

  if( $use_ajax ){
    $self->render( json =>  \@lines );
  }
  else{
    $self->stash( files => \@file_list, lines => \@lines, curr_file => $type.'.log' );
    $self->render( template => 'display/log' );  
  }
}

#################################################################################

1;
