package MTeam;

use Data::Dumper;
use utf8;
use BibSpace::Model::MAuthor;
use Text::BibTeX;    # parsing bib files
use 5.010;           #because of ~~ and say
use DBI;
use Moose;

has 'id'     => ( is => 'rw' );
has 'name'   => ( is => 'rw' );
has 'parent' => ( is => 'rw' );

####################################################################################
sub static_all {
    my $self = shift;
    my $dbh  = shift;

    my $qry = "SELECT id,
            name,
            parent
        FROM Team";
    my @objs;
    my $sth = $dbh->prepare($qry);
    $sth->execute();

    while ( my $row = $sth->fetchrow_hashref() ) {
        my $obj = MTeam->new(
            id     => $row->{id},
            name   => $row->{name},
            parent => $row->{parent}
        );
        push @objs, $obj;
    }
    return @objs;
}
####################################################################################
sub static_get {
    my $self = shift;
    my $dbh  = shift;
    my $id   = shift;

    my $qry = "SELECT id,
                    name,
                    parent
          FROM Team
          WHERE id = ?";

    my $sth = $dbh->prepare($qry);
    $sth->execute($id);
    my $row = $sth->fetchrow_hashref();

    if ( !defined $row ) {
        return undef;
    }

    return MTeam->new(
        id     => $id,
        name   => $row->{name},
        parent => $row->{parent}
    );
}
####################################################################################
sub update {
    my $self = shift;
    my $dbh  = shift;

    my $result = "";

    if ( !defined $self->{id} ) {
        say
            "Cannot update. MTeam id not set. The entry may not exist in the DB. Returning -1. Should never happen!";
        return -1;
    }

    my $qry = "UPDATE Team SET
                name=?,
                parent=?
            WHERE id = ?";
    my $sth = $dbh->prepare($qry);
    $result = $sth->execute( $self->{name}, $self->{parent}, $self->{id} );
    $sth->finish();
    return $result;
}
####################################################################################
sub insert {
    my $self   = shift;
    my $dbh    = shift;
    my $result = "";

    my $qry = "
        INSERT INTO Team(
        name,
        parent
        ) 
        VALUES (?,?);";
    my $sth = $dbh->prepare($qry);
    $result = $sth->execute( $self->{name}, $self->{parent}, );
    $self->{id} = $dbh->last_insert_id( '', '', 'Team', '' );
    $sth->finish();
    return $self->{id};
}
####################################################################################
sub save {
    my $self = shift;
    my $dbh  = shift;

    warn "No database handle supplied!" unless defined $dbh;

    my $result = "";

    if ( defined $self->{id} and $self->{id} > 0 ) {

        # say "MTeam save: updating ID = ".$self->{id};
        return $self->update($dbh);
    }
    elsif ( defined $self and !defined $self->{name} ) {
        warn "Cannot save MTeam that has no name";
        return -1;
    }
    else {
        my $inserted_id = $self->insert($dbh);
        $self->{id} = $inserted_id;

        # say "MTeam save: inserting. inserted_id = ".$self->{id};
        return $inserted_id;
    }
}
####################################################################################
sub delete {
    my $self = shift;
    my $dbh  = shift;

    my $qry    = "DELETE FROM Team WHERE id=?;";
    my $sth    = $dbh->prepare($qry);
    my $result = $sth->execute( $self->{id} );
    $self->{id} = undef;

    return $result;
}
####################################################################################
sub static_get_by_name {
    my $self = shift;
    my $dbh  = shift;
    my $name = shift;

    my $sth = $dbh->prepare("SELECT id FROM Team WHERE name=?");
    $sth->execute($name);
    my $row = $sth->fetchrow_hashref();
    my $id = $row->{id} || -1;

    if ( $id > 0 ) {
        return MTeam->static_get( $dbh, $id );
    }
    return undef;
}
################################################################################
sub members {
    my $self = shift;
    my $dbh  = shift;


    my $qry = "SELECT author_id, start, stop
            FROM Author_to_Team 
            WHERE team_id=?";

    my $sth = $dbh->prepare($qry);
    $sth->execute( $self->{id} );

    my @authors;
    while ( my $row = $sth->fetchrow_hashref() ) {
        my $author = MAuthor->static_get( $dbh, $row->{author_id} )
            if defined $row->{author_id} and $row->{author_id} ne '';

# if author is undef then such author does not exists and the table Author_to_Team contains trash!
        push @authors, $author if defined $author;

        # my $start = $row->{start};
        # my $stop  = $row->{stop};
    }
    return @authors;
}
####################################################################################
sub get_membership_beginning {
    my $self   = shift;
    my $dbh    = shift;
    my $author = shift;

    die("Author is undefined") unless defined $author;

    return $author->joined_team( $dbh, $self );
}
####################################################################################
sub get_membership_end {
    my $self   = shift;
    my $dbh    = shift;
    my $author = shift;

    die("Author is undefined") unless defined $author;

    return $author->left_team( $dbh, $self );
}
####################################################################################
sub tags {
    my $self = shift;
    my $dbh  = shift;
    my $type = shift || 1;

    my @params;

    my $qry = "SELECT DISTINCT Tag.id as tagid
                FROM Entry
                LEFT JOIN Exceptions_Entry_to_Team  ON Entry.id = Exceptions_Entry_to_Team.entry_id
                LEFT JOIN Entry_to_Author ON Entry.id = Entry_to_Author.entry_id 
                LEFT JOIN Author ON Entry_to_Author.author_id = Author.id 
                LEFT JOIN Author_to_Team ON Entry_to_Author.author_id = Author_to_Team.author_id 
                LEFT JOIN Entry_to_Tag ON Entry.id = Entry_to_Tag.entry_id 
                LEFT JOIN Tag ON Tag.id = Entry_to_Tag.tag_id 
                WHERE Entry.bibtex_key IS NOT NULL 
                AND Tag.type = ?";

    push @params, $type;

    push @params, $self->{id};
    push @params, $self->{id};
    $qry .= "AND ( ( Exceptions_Entry_to_Team.team_id=? ) OR 
                   ( Author_to_Team.team_id=? AND start <= Entry.year  AND ( stop >= Entry.year OR stop = 0 ) )
                )";

    my $sth = $dbh->prepare_cached($qry);
    $sth->execute(@params);

    my @tags;

    while ( my $row = $sth->fetchrow_hashref() ) {
        my $tag = MTag->static_get( $dbh, $row->{tagid} );
        push @tags, $tag if defined $tag;
    }

    return @tags;
}
####################################################################################
no Moose;
__PACKAGE__->meta->make_immutable;
1;