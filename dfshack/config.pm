package config;

use strict;
use Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);

use File::Spec;

$VERSION = 1.00;
@ISA = qw(Exporter);
@EXPORT = ();
@EXPORT_OK = qw(read);

my $homeconfig = ".dfshack/config";
my $globalconfig = "/etc/dfshack/config";

sub read {
	my $file = shift || undef;
	my $config;
	my @readconfigs;

	if(!$file) {
		if(-e $globalconfig) {
			$file = $globalconfig;
		} 
		else {
			die "no config file found! $!\n";
		}
	}

	push @readconfigs, $file;
	readconfig($file, $config);

	# read custom user configuration
	if($config->{'sourcedir'}) {
		$homeconfig = File::Spec->join($config->{'sourcedir'}, $homeconfig);
		if(-e $homeconfig) {
			push @readconfigs, $homeconfig ;
			readconfig($homeconfig, $config);
		}
	}
	else {
		die "No sourcedir provided!\n";
	}

# read configs referenced in new config files,
# making sure that we don't recursively read configs
	while(!grep($config->{'config'},@readconfigs)  ) {
		if($config->{'config'}) {
			if(-e $config->{'config'}) {
				push @readconfigs, $config->{'config'};
				readconfig($config->{'config'}, $config);
			} 
			else {
				warn "$config->{'config'} not a valid file!\n";
			}
		}
	}
	return $config;
}

sub readconfig {
	my $file = shift || warn "no config file provided\n";
	my $config = shift;

	open(my $fh, '<', $file) or die $!;

	while(my $line = <$fh>) {
		next if($line =~ /^\s?#/); #strip comment lines
		next if($line =~ /^\s?$/); #strip blank lines

		#split lines based on <tag>=<value> #comment
		my ($tag, $value) = split(/\s?([^=]+)\s?=\s?([^#]+)/, $line);
		$config->{$tag} = $value;
	}

	close($fh);

	return $config;
}

#return true
"false";

