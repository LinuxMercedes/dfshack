package log;

use strict;

sub new {
  my $class = shift;
  my $self = {};
  if(@_) {
    $self->{'logfile'} = shift;
  } else {
    warn "No log file provided.\n";
  }

  bless($self, $class);

  if($self->{'logfile'}) {
    &$self->openlog;
  }

  return $self;
}

sub openlog {
  my $self = shift;
  open($self->{'fh'}, '>>', $self->{'logfile'}) or die $!;
}

sub log {
  my $self = shift;
  my $mesg = shift || "\n";

  print $self->{'fh'} "$mesg\n";
}

sub DESTROY {
  my $self = shift;

  close($self->{'fh'});
}

