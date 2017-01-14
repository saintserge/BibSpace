# This code was auto-generated using ArchitectureGenerator.pl on 2017-01-14T17:18:02
package BibSpace::Model::DAO::DAOFactory;

use namespace::autoclean;
use Moose;
use BibSpace::Model::DAO::MySQLDAOFactory;
use BibSpace::Model::DAO::RedisDAOFactory;
use BibSpace::Model::DAO::ArrayDAOFactory;

# this class has logger, because it may want to log somethig as well 
# thic code forces to instantiate the abstract factory first and then calling getInstance
has 'logger' => ( is => 'ro', does => 'BibSpace::Model::ILogger', required => 1);


sub getInstance {
    my $self        = shift;
    my $factoryType = shift;
    my $handle      = shift;

    die "Factory type not provided!" unless $factoryType;
    die "Connection handle not provided!" unless $handle;

    try{
        my $class = $factoryType;
        Class::Load::load_class($class);
        return $class->new( logger => $self->logger, handle => $handle );
    }
    catch{
        die "Requested unknown type of DaoFactory: '$factoryType'.";
    };

}
__PACKAGE__->meta->make_immutable;
no Moose;
1;
