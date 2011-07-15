package log;

use strict;

use Log::Handler;
use lib "./config.pm";

sub get {
	if(Log::Handler->exists_logger("dfshack")) {
		return Log::Handler->get_logger("dfshack");
	}
	else {
		return create();
	}	
}

sub create {
	my $config = config::read();

	my $log = Log::Handler->create_logger("dfshack");

	$log->add(
		screen => {
			log_to => "STDOUT",
			maxlevel => "debug", 
			minlevel => "debug",
		},	
	);

	if($config->{'log file'}) {
		$log->add(
			file => {
				maxlevel => 7,
				minlevel => 0,

				filename => $config->{'log file'},
				filelock => 1,
				fileopen => 1,
				reopen => 1,
				autoflush => 1,
				permissions => "0660",
				utf8 => 1,
			},
		);
	}
	else {
		$log->add(
			screen => {
				maxlevel => 7,
				minlevel => 0,

				log_to => "STDERR",
			},
		);
	}

	$log->set_level(
		my $alias => {
			minlevel => $config->{'log minimum'},
			maxlevel => $config->{'log maximum'},
		}
	);

	return $log;
}

sub set_level {
	my $min = shift;
	my $max = shift;

	my $log = get();
	$log->set_level(
		my $alias => {
			minlevel => $min,
			maxlevel => $max,
		}
	);
}

