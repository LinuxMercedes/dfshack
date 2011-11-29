#! /usr/bin/perl

use strict;
use warnings;

use Fuse;
use POSIX qw(ENOENT ENOSYS ENOTDIR EEXIST EPERM EAGAIN O_RDONLY O_RDWR O_APPEND O_CREAT);
use Fcntl qw(S_ISBLK S_ISCHR S_ISFIFO SEEK_SET S_ISREG S_ISFIFO S_IMODE S_ISCHR S_ISBLK S_ISSOCK);
use Time::HiRes qw(time tv_internal usleep);
use Getopt::Long;

my %extraopts = (
		'threaded' => 0,
		'debug' => 0,
		);

my $dfsmount = "";
my $mountpoint = "";
my $pidfile = "";

GetOptions(
		'debug' => sub {
			$extraopts{'debug'} = 1;
		},
		'use-threads' => sub {
			$extraopts{'threaded'} = 0; # NO THREADS FOR YOU
		},
		'dfs=s' => \$dfsmount,
		'mount=s' => \$mountpoint,
		'pidfile=s' => \$pidfile,
) or die "could not parse options";

my %symlinks = ();
my $symlinkupdate = undef;

sub checklock {
	my $lock = shift;
	my $lockfile = fixup(".dfshack/.$lock");

	my $start = time();
	my $elapsed = tv_internal($start);

	while((-e $lockfile) && $elapsed < 5) {
		print $elapsed . "\n";
		usleep(10_000); #Wait for .1 second
	}

	if(-e $lockfile) {
		return -EAGAIN();
	}

	return undef;
}

sub readlink {
	my $linkfile = fixup(".dfshack/symlinks");

	my $rv = checklock("symlink");
	return $rv if $rv;

	%symlinks = ();

	if(! -e $linkfile) {
		return undef;
	}

	open(my $lfh, '<', $linkfile);

	while(my $line = <$lfh>) {
		if($line =~ /(.+)\0(.+)/) {
			$symlinks{$1} = $2;
		}
	}

	close($lfh);

	return undef;
}

sub debug {
	my $string = shift;
	print $string if $extraopts{'debug'};
}

sub fixup {
	my $file = shift;
	return $dfsmount . $file;
}

sub d_getattr {
	my $file = fixup(shift);

	debug("d_gettattr: " . $file);

	my @stats = lstat($file);
	return -$! unless @stats;
	return @stats;
}

sub d_getdir {
	my $dirname = fixup(shift);

	opendir(my $dir, $dirname) || return -ENOENT();

	my @files = readdir($dir);
	closedir($dir);
	return (@files, 0);
}

sub d_open {
	my $file = fixup(shift);
	my $mode = shift;

	sysopen(my $fh, $file, $mode) || return -$!;

	close($fh);
	return 0;
}

sub d_read {
	my $file = fixup(shift);
	my $bufsize = shift;
	my $offset = shift;
	my $rv = -ENOSYS();

	return -ENOENT() unless -e($file); # = fixup($file)
	
	my $size = -s $file;

	open(my $handle, $file) or return -ENOSYS();
	if(seek($handle, $offset, SEEK_SET)) {
		read($handle, $rv, $bufsize);
	}

	return $rv;
}

sub d_write {
	my $file = fixup(shift);
	my $buf = shift;
	my $off = shift;
	my $rv;
	return -ENOENT() unless -e($file); 
	my $fsize = -s $file;

	return -ENOSYS() unless open(my $fh, '+<', $file);
	if($rv = seek($fh, $off, SEEK_SET)) {
		$rv = print $fh $buf;
	}
	$rv or $rv = -ENOSYS();
	close($fh);
	return length($buf);
}

sub err {
	return (-shift || -$!);
}

#copied straight out of the tutorial and probably wrong
sub d_readlink {
	print "readlink\n";
	return readlink(fixup(shift));
}

sub d_unlink {
	print "unlink\n";
#	return unlink(fixup(shift)) ? 0 : -$!;
}

sub d_symlink {
	print "symlink\n";
	return symlink(shift, fixup(shift)) ? 0 : -$!;
}

sub d_link {
	print "hardlink\n";
#	return link(fixup(shift), fixup(shift)) ? 0 : -$!;
	return -ENOSYS();
}

sub d_rename {
	my $old = fixup(shift);
	my $new = fixup(shift);
  return rename($old, $new) ? 0 : -ENOENT();
}

sub d_chown {
	my $file = fixup(shift);
	my $uid = shift;
	my $gid = shift;

	local $!; #huh?
	print "no file $file\n" unless -e $file;
	lchown($uid, $gid, $file);

	return -$!;
}

sub d_chmod {
	my $file = fixup(shift);
	my $mode = shift;

	return chmod($mode, $file) ? 0 : -$!;
}

sub d_truncate {
	my $file = fixup(shift);
	my $length = shift;

	return truncate($file, $length) ? 0 : -$!;
}

sub d_utime {
	my $file = fixup(shift);
	my $atime = shift;
	my $utime = shift;

	return utime($atime, $utime, $file) ? 0 : -$!;
}

sub d_mkdir {
	my $file = fixup(shift);
	my $perm = shift;

	return mkdir($file, $perm) ? 0 : -$!;
}

sub d_rmdir {
	my $file = fixup(shift);

	return rmdir($file) ? 0 : -$!;
}

sub d_mknod {
	my $file = fixup(shift);
	my $modes = shift;
	my $dev = shift;

	undef $!;

	if(S_ISREG($modes)) {
		open(my $fh, '>', $file) or return -$!;
		print $fh '';
		close $fh;
		chmod S_IMODE($modes), $file;
		return 0;
	}
	elsif (S_ISFIFO($modes)) {
		return POSIX::mkfifo($file, S_IMODE($modes)) ? 0 : -POSIX::errno();
	}
	elsif (S_ISCHR($modes) || S_ISBLK($modes)) {
		mknod ($file, $modes, $dev);
		return -$!;
	}
	#S_ISSOCK?
	else {
		return -ENOSYS();
	}
}

sub d_statfs {
	return -ENOSYS(); #lol suckers
}

$mountpoint = shift(@ARGV) if @ARGV;

if(! -d $mountpoint) {
	die "ERROR: attempted to mount to nonexistent directory $mountpoint\n";
	return -ENOTDIR();
}

if(! -e $dfsmount ) {
	die "Invalid dfs mount point $dfsmount\n";
}

if(! -d $dfsmount ) {
	die "dfs mount $dfsmount is not a directory.\n";
}

my $pid = fork();
defined $pid or die "fork() failed: $!";

if($pid > 0) { #parent
	exit(0);
}

if($pidfile) { # child
	open(my $pfh, '>', $pidfile);
	print $pfh $$, "\n";
	close $pfh;
}
else { #failed to fork
	die "Could not spawn fuse driver $!";
}

if(! -d fixup(".dfshack")) {
	mkdir(fixup(".dfshack"), 0700);
}

Fuse::main(
		'mountpoint' => $mountpoint,
		'getattr' => 'main::d_getattr',
		'readlink' => 'main::d_readlink',
		'getdir' => 'main::d_getdir',
		'mknod' => 'main::d_mknod',
		'mkdir' => 'main::d_mkdir',
		'unlink' => 'main::d_unlink',
		'rmdir' => 'main::d_rmdir',
		'symlink' => 'main::d_symlink',
		'rename' => 'main::d_rename',
		'link' => 'main::d_link',
		'chmod' => 'main::d_chmod',
		'chown' => 'main::d_chown',
		'truncate' => 'main::d_truncate',
		'utime' => 'main::d_utime',
		'open' => 'main::d_open',
		'read' => 'main::d_read',
		'write' => 'main::d_write',
		'statfs' => 'main::d_statfs',
		%extraopts,
		);

