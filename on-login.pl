#/usr/bin/perl 

use strict;
use warnings;
use dfshack::config;
use dfshack::log;

my $config = dfshack::config::read();
my $loglevel = $config->{'log level'};
my $logfile = $config->{'log file'};

my $log = dfshack::log->new($logfile, $loglevel);


 