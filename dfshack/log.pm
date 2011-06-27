package log;

use strict;

my $logh;

my @levels = qw(None Info Warn Debug);

sub new {
  my $class = shift;
  my $self = {};
	
	$self->{'logfile'} = shift || "/var/log/dfshack.log";
	$self->{'maxlevel'} = shift || 3;

  bless($self, $class);

  if($self->{'logfile'}) {
    &$self->openlog;
  }

  return $self;
}

sub openlog {
  my $self = shift;
  open($logh, '>>', $self->{'logfile'}) or die $!;
}

sub log {
  my $self = shift;
	my $mesg = shift || "\n";
	my $level = shift || 1;

	if($level <= $self->{'maxlevel'}) {
		print $logh $levels[$level].": $mesg\n";
	}
}

sub DESTROY {
  my $self = shift;

  close($logh);
}

