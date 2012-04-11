package
    miniautorfile;     # hide from PAUSE
use strict;
use warnings;
use warnings FATAL => qw{ uninitialized };
use autodie;
use 5.10.0;
################################################################
=pod
=head1 Title
  miniautorfile.pm --- mini data base for a role-based access control (RBAC) file.
=head1 Invocation
  $ perl miniautorfile.pm
shows off how this module works.  The .pm invokation will also create
a suitable sample file in /tmp/tmpusers.txt.
=head1 Versions
  0.0: April 11 2012
=cut
################################################################
# file format: role:privilege1:privilege2:privilege3
#              role1:privilege1:privilege3
################################################################
sub new {
  my ($class_name, $authorfile)= @_;
  (-e $authorfile) or die "You must create a user-readable and user-writable authorization file first.\n";
  ## load persistent user information from an existing authorization file
  my %roles;
  open(my $FIN, "<", $authorfile);
  while (<$FIN>) {
    (/^\#/) and next; ## skip comments
    (/\w/) or next;  ## skip empty lines
    (!/([\w :\\])/) and die "Your authorization file has a non-word character ($1), other than : and \\ on line $.: $_\n";
    my @values= split(/:/);
    my $role = pop(@values);
    my $privs;
    foreach my $priv (@values){
       $privs->{$priv} = 1;
    }
    $roles{$role}= $privs;
  }
  close($FIN);
  return bless({ authorfile => $authorfile, %roles }, $class_name);
}
################################################################
sub userexists {
  my $self=shift;
  ($_[0]) or return undef;
  return ((exists($self->{$_[0]}))?($_[0]):undef);
}
################################################################
sub userinfo {
  my $self=shift;
  ($_[0]) or return undef;
  return $self->{$_[0]};
}
################################################################
sub checkuserpw {
  my $self=shift;
  ($_[0]) or return undef;
  ($_[1]) or return undef;
  my $pwinfile= $self->{$_[0]}->{'password'};
  say "\t[minipw---Trying to authenticate $_[0] ($pwinfile) with $_[1]\n]";
  return undef unless exists($self->{$_[0]});
  return undef unless ($pwinfile eq $_[1]);
  return $_[0];
}
################################################################
sub adduser {
  my $self=shift;
  foreach (@_) { (/^[\w ]+$/) or return "we allow only word characters, not '$_'"; }
  ($_[0] =~ /authorfile/) and return "authorfile is a reserved word";
  $self->{$_[0]}= { 'uid'=>$_[0], 'password' => $_[1], 'privileges' => $_[2], 'username' => $_[3] };
  return$self->rewritefile();
}
################################################################
sub rmuser {
  my $self=shift;
  ($_[0] =~ /^[\w ]+$/) or return "we allow only word characters, not '$_'";
  ($_[0] =~ /authorfile/) and return "authorfile is a reserved word";
  delete $self->{$_[0]};
  return$self->rewritefile();
}
################################################################
sub rewritefile {
  my $self=shift;
  open(my $FOUT, ">", $self->{authorfile});
  say $FOUT "## format: username:password:privilegelevel:full name";
  say $FOUT "## last updated on ".scalar(localtime).", ".time();
  foreach my $uid (keys %{$self}) {
    ($uid =~ /authorfile/) and next;  # a pseudo-key
    foreach my $field (qw/uid password privileges username/) {
      print $FOUT $self->{$uid}->{$field}.":";
    }
    print $FOUT "\n";
  }
  close($FOUT);
  return "ok";
}
################################################################
sub numroles {
  my $self=shift;
  return scalar keys %{$self};
}
################################################################
if ($0 eq "miniautorfile.pm") {
  say "$0 invoked directly (TEST Mode)";
  sub mkminiautorfile {
    my $filename="miniautorfile.txt";
    open(my $FOUT, ">", $filename);
    say $FOUT "## format: username:password:privilegelevel:full name";
    close($FOUT);
    return $filename;
  }
  my $fname=mkminiautorfile();
  sub _displaysecretfile {
    my $self=shift;
    use Data::Dumper;
    print Dumper($self);
    ## sample access: ($self->{'albert'}->{'password'});
  };
  ## true testing code
  package main;
  my $pw= miniautorfile->new($fname);
  say "Before Insertion";
  $pw->_displaysecretfile();
  ($pw->adduser('sigmund', 'psycho', 'instructor', 'Sigmund Freud') eq 'ok') or die 'Cannot add sigmund\n';
  ($pw->adduser('albert','relativity','instructor','Albert Einstein') eq 'ok') or die 'cannot add albert\n';
  ($pw->adduser('richard','qed','instructor','Richard Feynman') eq 'ok') or die 'cannot add richard\n';
  ($pw->adduser('dummy','knownothing','student','Not So Anonymous Student') eq 'ok') or die 'cannot add dummy\n';
  ($pw->adduser('sigmund','psycho','instructor','Sigmund Freud') eq 'ok') or die 'cannot add sigmund\n';
  say "After Insertion";
  $pw->_displaysecretfile();
  foreach (qw/albert angstrom/) {
    print "Does '$_' exist? ".($pw->userexists($_) || "no")."\n";
    print "Does '$_' have password 'relativity'? ".($pw->checkuserpw($_, 'relativity') || "no")."\n";
  }
}
1;
