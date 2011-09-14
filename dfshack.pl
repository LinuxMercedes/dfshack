#! /usr/bin/perl

use strict;
use warnings;

use Fuse;
use POSIX qw(ENOENT ENOSYS EEXIST EPERM O_RDONLY O_RDWR O_APPEND O_CREAT);
use Fcntl qw(S_ISBLK S_ISCHR S_ISFIFO SEEK_SET S_ISREG S_ISFIFO S_IMODE S_ISCHR S_ISBLK S_ISSOCK);
use Getopt::Long;

my $debug = undef;
my $dfsmount = "";
my $mountpoint = "";

GetOptions(
		'debug' => sub {
			$debug = 1;
		},
		'dfs=s' => \$dfsmount,
		'mount=s' => \$mountpoint,
) || die "could not parse options";

sub debug{
	my $string = shift;
	print $string if $debug;
}

          