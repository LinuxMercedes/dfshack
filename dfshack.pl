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

sub d_getattr {
	my $filename = shift;

	debug("d_gettattr: " . $filename);

	my @stats = lstat($file);
	return -$! unless @list;
	return @list;
}

sub d_getdir {
	my $dirname = shift;

	opendir(my $dir, $dirname) || return -ENOENT();

	my @files = readdir($dir);
	closedir($dir);
	return (@files, 0);
}

sub d_open {
	my $file = shift;
	my $mode = shift;

	sysopen(my $fh, $file, $mode) || return -$!;

	close($fh);
	return 0;
}

sub d_read {
	my $file = shift;
	my $bufsize = shift;
	my $offset = shift;
	my $rv = -ENOSYS();

	return -ENOENT() unless -e($file); # = fixup($file)
	
	my $size = -s $file;

	open(my $handle, $file) || return -ENOSYS();
	if(seek($handle, $off, SEEK_SET)) {
		read($handle, $rv, $bufsize);
	}

	return $rv;
}
