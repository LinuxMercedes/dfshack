#! /usr/bin/perl

use strict;
use warnings;

use Fuse;
use POSIX qw(setsid ENOENT ENOSYS ENOTDIR EEXIST EPERM EAGAIN O_RDONLY O_RDWR O_APPEND O_CREAT);
use Fcntl qw(S_ISBLK S_ISCHR S_ISFIFO SEEK_SET S_ISREG S_ISFIFO S_IMODE S_ISCHR S_ISBLK S_ISSOCK S_IRWXU);
use Time::HiRes qw(time gettimeofday tv_interval usleep);
use Getopt::Long;
use Lchown qw(lchown);
use File::Basename;
use File::Spec::Functions qw(catdir catfile devnull tmpdir rootdir);
use File::Util qw(SL); # since File::Spec has no way to directly access the path separator
use Fcntl qw(:mode);
use Filesys::Statvfs;
use DBI;

use Data::Dumper;

our $time_epsilon = 1;

our $datadir = catdir(rootdir(), ".dfshack");

our %extraopts = (
		'threaded' => 0,
		'debug' => 0,
		'mountopts' => '',
		);

our $dfsmount;
our $mountpoint;
our $pidfile;

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
		'o=s' => \$extraopts{'mountopts'},
) or die "could not parse options";

our %symlinks = ();
our $symlinkupdate = undef;

our %permissions = ();
our $permissionsupdate = undef;

our $dbh;

sub db_connect {
	debug("Connect to sqlitedb");
	return DBI->connect("dbi:SQLite:dbname=" . fixup(catfile($datadir, "sqlitedb")), "", "");
}

sub db_disconnect {
	debug("Disconnect from sqlitedb");
	return shift->disconnect;
}

sub db_create {
	my $sth;

	debug("Create sqlitedb");

	$sth = $dbh->prepare("CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY ASC, fullname TEXT UNIQUE NOT NULL, dirname TEXT NOT NULL, filename TEXT NOT NULL)");
	$sth->execute();

	$sth = $dbh->prepare("CREATE TABLE IF NOT EXISTS permissions(id INTEGER PRIMARY KEY, perms INTEGER NOT NULL)");
	$sth->execute();

	$sth = $dbh->prepare("CREATE TABLE IF NOT EXISTS symlinks(id INTEGER PRIMARY KEY, dest TEXT NOT NULL)");
	$sth->execute();
}

sub db_import {

}

# Get the DB id of a file
sub get_id {
	my $file = shift;
	debug($file);

	my $sth = $dbh->prepare("SELECT id FROM files WHERE fullname=?");
	$sth->execute($file);
	my $id_row = $sth->fetch;

	return undef unless defined $id_row;
	return $id_row->[0];
}

# Determine if this file already exists
sub is_file {
	my $file = shift;
	debug($file);
	return defined get_id($file);
}

# Add a file to the DB if it doesn't already exist
sub create_file {
	my $file = shift;
	debug($file);
	my $dirname = dirname($file);
	my $filename = basename($file);

	my $sth = $dbh->prepare("INSERT INTO files VALUES (NULL, ?, ?, ?)");
	return $sth->execute($file, $dirname, $filename);
}

# Delete a file
sub del_file {
	my $file = shift;
	
	my $id = get_id($file);
	return unless defined $id;
	
	my $sth = $dbh->prepare("DELETE FROM symlinks WHERE id=?");
	$sth->execute($id);

	$sth = $dbh->prepare("DELETE FROM permissions WHERE id=?");
	$sth->execute($id);

	$sth = $dbh->prepare("DELETE FROM files WHERE id=?");
	$sth->execute($id);
}

# Move a file based on the name
sub move_file {
	my $src = shift;
	my $dest = shift;
	debug($src);
	debug($dest);

	my $id = get_id($src);
	if(!defined($id)) {
		#create_file($dest); Not sure if want
		return 1;
	}

	my $sth = $dbh->prepare("UPDATE files SET fullname=?, dirname=?, filename=? WHERE id=?");
	return $sth->execute($dest, dirname($dest), basename($dest), $id);
}

# Move all files in a directory
sub move_dir {
	my $src = shift;
	my $dest = shift;
	debug($src);
	debug($dest);

	my $sth = $dbh->prepare("SELECT * FROM files WHERE dirname LIKE ?");
	$sth->execute($src . "%");

	my @files;
	my $up = $dbh->prepare("UPDATE files SET fullname=?, dirname=? WHERE id=?");
	while(my $res = $sth->fetch) {
		debug("fetch: " . $res->[1]);
		if($res->[2] =~ /^$src(\Q${\SL}\E.+|)$/) {
			my $dirname = catdir($dest, $1);
			my $fullname = catfile($dirname, $res->[3]);
			$up->execute($fullname, $dirname, $res->[0]);
			debug("matched! " . $fullname);
		}
	}
}
		
# Determine if a file is a symlink
sub is_symlink {
	return defined get_symlink(shift);
}

# Create a symlink in the DB
sub make_symlink {
	my $file = shift;
	my $dest = shift;
	
	create_file($file);
	my $id = get_id($file);
	
	my $sth = $dbh->prepare("INSERT INTO symlinks VALUES(?,?)");
	return $sth->execute($id, $dest);
}

# Get the target/destination of a symlink
sub get_symlink {
	my $file = shift;
	
	my $id = get_id($file);
	return undef unless defined $id;

	my $sth = $dbh->prepare("SELECT dest FROM symlinks WHERE id=?");
	$sth->execute($id);
	my $res = $sth->fetch;
	return undef unless defined $res;
	return $res->[0];
}

# Get all symlinks in a directory
sub get_dir_symlinks {
	my $dir = shift;
	debug($dir);

	my $sth = $dbh->prepare("SELECT filename FROM symlinks INNER JOIN files  ON files.id = symlinks.id WHERE dirname=?");
	$sth->execute($dir);
	my @names;
	while(my $res = $sth->fetch) {
		push(@names, $res->[0]);
	}
	
	return @names;
}

sub checklock {
	my $lock = shift;
	my $lockfile = fixup(catfile($datadir, ".$lock"));

	my $start = [gettimeofday];
	my $elapsed = $start;

	while((-e $lockfile) && $elapsed < 5) {
		print $elapsed . "\n";
		usleep(10_000); #Wait for .1 second
		$elapsed = tv_interval($start);
	}

	if(-e $lockfile) {
		return -EAGAIN();
	}

	return undef;
}

sub readfile {
	my $readtype = shift;
	my $hash = shift;
	my $modified = shift;

	my $filename = fixup(catfile($datadir, "$readtype"));
	
	debug("readfile: " . $filename);

# No symlinks file -- we have nothing to read!
	if(! -e $filename) {
		%$hash = ();
		debug("readfile: no file to read");
		return undef;
	}	
	
# Check to see if we're busy writing; hang for a while
# and then either carry on or fail
	my $rv = checklock($readtype);
	return $rv if $rv;

  my $mtime = (stat($filename))[9];

# If we're already up-to-date, don't bother
# reading the file.
	if($$modified) {
		if(abs($mtime - $$modified) < $time_epsilon) {
			debug("readfile: up-to-date");
			return undef;
		}
	}

# Update the modified time
	$$modified = $mtime;
	
	%$hash = ();

	open(my $fh, '<', $filename);

# Read the null-delimited file
	while(my $line = <$fh>) {
		if($line =~ /(.+)\0(.+)/) {
			$hash->{$1} = $2;
		}
	}

	close($fh);

	return undef;
}

sub writefile {
	my $writetype = shift;
	my $hash = shift;
	my $modified = shift;

	my $filename = fixup(catfile($datadir, "$writetype"));

	debug("writefile: " . $filename);

	my $rv = checklock($writetype);
	return $rv if $rv;

	if(-e $filename && ($$modified > (stat($filename))[9])) {
		debug("WARNING: link file modified in the future?");
	}

	open(my $lock, '>', fixup(catfile($datadir, ".$writetype")));
	close($lock);

	open(my $fh, '>', $filename);

	while(my($k, $v) = each(%$hash)) {
		print $fh $k . "\0" . $v . "\n";
	}

	close($fh);

	unlink(fixup(catfile($datadir,".$writetype")));

	return undef;
}

sub writelinks {
	return writefile("symlinks", \%symlinks, \$symlinkupdate);
}

sub readlinks {
	return readfile("symlinks", \%symlinks, \$symlinkupdate);
}

sub writepermissions {
	return writefile("permissions", \%permissions, \$permissionsupdate);
}

sub readpermissions {
	return readfile("permissions", \%permissions, \$permissionsupdate);
}

sub debug {
	my $string = shift;
	my $line = (caller(1))[2];
	my $sub = (caller(1))[3];
	print $line . ":" . $sub . ": "; 
	print $string . "\n" if($extraopts{'debug'} && $string);
	print "nothing to print here\n" if($extraopts{'debug'}) && !$string;
}

sub fixup {
	my $file = shift;
	return catfile($dfsmount, $file);
}

sub d_getattr {
	my $file = shift;
	my @stats;

	debug("d_getattr: " . $file);

	# Update cached data
	return -$! if readlinks();
	return -$! if readpermissions();

	if(my $link = get_symlink($file)) {
		debug("d_getattr: is symlink");
		@stats = lstat(fixup(catfile($datadir, "sqlitedb")));

		my $linkfile = fixup(catfile(dirname($file), $file));
		if(-e $linkfile) {
			my @lstats = lstat($linkfile);
			$stats[9] = $lstats[9];
			$stats[10] = $lstats[10];
			$stats[11] = $lstats[11];
		}

		$stats[8] = length($link);

		# Convert the mode from a regular file to a link
		$stats[2] = (($stats[2] & !S_IFREG) | S_IFLNK);
	}
	else {
		debug("d_getattr: is regular file");

		@stats = lstat(fixup($file));
	}

	if($permissions{$file}) {
		debug("d_getattr: modifying permissions");
		$stats[2] = (($stats[2] & !S_IRWXU) | $permissions{$file});
	}
		
	return -$! unless @stats;
	return @stats;
}

sub d_getdir {
	my $dirname = shift;
	debug("d_getdir: " . $dirname);

	return -EAGAIN() if readlinks();

	opendir(my $dir, fixup($dirname)) || return -ENOENT();

	my @files = readdir($dir);
	closedir($dir);

	foreach my $k (keys(%symlinks)) {
		debug("d_getdir link: " . $k);
		push(@files, basename($k)) if($k =~ /^$dirname\Q${\SL}\E?[^\q${\SL}\E]+$/);
	}

	push(@files, get_dir_symlinks($dirname));
	return (@files, 0);
}

sub d_open {
	my $file = shift;
	my $mode = shift;
	debug("d_open: " . $file);

	sysopen(my $fh, fixup($file), $mode) || return -$!;

	close($fh);
	return 0;
}

sub d_read {
	my $file = shift;
	my $bufsize = shift;
	my $offset = shift;
	my $rv = -ENOSYS();

	debug("d_read: " . $file);

	$file = fixup($file);

	return -ENOENT() unless -e($file);
	
	my $size = -s $file;

	open(my $handle, $file) or return -ENOSYS();
	if(seek($handle, $offset, SEEK_SET)) {
		read($handle, $rv, $bufsize);
	}

	return $rv;
}

sub d_write {
	my $file = shift;
	my $buf = shift;
	my $off = shift;
	my $rv;
	debug("d_write: " . $file);
	
	$file = fixup($file);
	
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

# Reads a symlink
sub d_readlink {
	my $file = shift;
	debug("d_readlink: " . $file);

	my $rv = get_symlink($file);
#	my $rv  = readlinks();
#
## fail on readlinks() error
#	if($rv) {
#		$! = $rv;
#		return undef;
#	}
#
#	$rv = $symlinks{$file};
	$! = -ENOENT() unless $rv; # Is this right?
	return $rv;
}

# Deletes a symlink
# Also deletes regular links?
sub d_unlink {
	my $file = shift;
	debug("d_unlink: " . $file);
	
	return -$! if readlinks();
	return -$! if readpermissions();

	if(delete $permissions{$file}) {
		writepermissions();
	}

#	if(delete $symlinks{$file}) {
#		writelinks();
#		return 0;
#	}

	del_file($file);

	local $!;
	unlink(fixup($file));
	return -$!;
}

sub d_symlink {
	my $old = shift;
	my $new = shift;

	debug("d_symlink: " . $old . " " . $new);
	
	return 0 if readlinks();

	if(-e fixup($new) || is_file($new)) {
		debug("d_symlink: $new exists");
		return 0; #fail
	}

#	$symlinks{$new} = $old;
#	my $rv = writelinks();
#	if($rv) {
#		debug("d_symlink: failed to write link file");
#		delete $symlinks{$new};
#		return 0;
#	}

	my $rv = make_symlink($new, $old);
	print "d_symlink return: $rv" if defined $rv;
	return 0 if defined $rv; # Failed to write
	debug("d_symlink: success!");

	return undef;
}

sub d_link {
	my $old = shift;
	my $new = shift;

	debug("d_link: " . $old . ' ' . $new);

	return link(fixup($old), fixup($new)) ? 0 : -$!;
}

sub d_rename {
	my $old = shift;
	my $new = shift;
	debug("d_rename: " . $old . " " . $new);

	my $rv; 
	my $ret;

	return $rv if $rv = readlinks();
	return $rv if $rv = readpermissions();

	if(-d fixup($old)) {
#		foreach my $file (keys %symlinks) {
#			debug("d_rename: " . $file);
#			if($file =~ /^$old\Q${\SL}\E(.+)/) {
#				$symlinks{catfile($new, $1)} = delete $symlinks{$file};
#			}
#		}
		move_dir($old, $new);
		foreach my $file (keys %permissions) {
			# match both files in the directory and the directory itself.
			if($file =~ /^$old\Q${\SL}\E(.+|)/) { 
				$permissions{catfile($new, $1)} = delete $permissions{$file};
			}
		}
	}

	if($permissions{$old}) {
		$permissions{$new} = delete $permissions{$old};
	}
	
	move_file($old, $new);

	if(-e fixup($old)){
		$ret = rename(fixup($old), fixup($new)) ? 0 : -ENOENT();
	}

	return $rv if $rv = writelinks();
	return $rv if $rv = writepermissions();

  return $ret;
}

sub d_chown {
	my $file = shift;
	my $uid = shift;
	my $gid = shift;
	
	debug("d_chown: " . $file);

	$file = fixup($file);

	local $!;
	debug("d_chown: no file $file") unless -e $file;
	lchown($uid, $gid, $file);

	return -$!;
}

sub d_chmod {
	my $file = shift;
	my $mode = shift;
	debug("d_chmod: " . $file);

	my $rv = readpermissions();
	if($rv) {
		return $rv;
	}

	$permissions{$file} = $mode;

	$rv = writepermissions();

	return 0 if !$rv;
	return $rv;
}

sub d_truncate {
	my $file = shift;
	my $length = shift;
	debug("d_truncate: " . $file);

	return truncate(fixup($file), $length) ? 0 : -$!;
}

sub d_utime {
	my $file = shift;
	my $atime = shift;
	my $utime = shift;
	debug("d_utime: " . $file);
	
	return utime($atime, $utime, fixup($file)) ? 0 : -$!;
}

sub d_mkdir {
	my $file = fixup(shift);
	my $perm = shift;
	debug("d_mkdir: " . $file);

	return mkdir($file, $perm) ? 0 : -$!;
}

sub d_rmdir {
	my $file = fixup(shift);
	debug("d_rmdir: " . $file);

	return rmdir($file) ? 0 : -$!;
}

sub d_mknod {
	my $file = shift;
	my $modes = shift;
	my $dev = shift;

	debug("d_mknod: " . $file);
	undef $!;

	return -EAGAIN() if readpermissions();

	if(S_ISREG($modes)) {
		open(my $fh, '>', fixup($file)) or return -$!;
		print $fh '';
		close $fh;
		$permissions{$file} = $modes;
		writepermissions();
		return 0;
	}
#	elsif (S_ISFIFO($modes)) {
#		return POSIX::mkfifo($file, S_IMODE($modes)) ? 0 : -POSIX::errno();
#	}
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
	debug("d_statfs");
	return (statvfs($dfsmount))[1,2,3,5,6,9]; #from perl-fuse unit test
}

# Implement this stuff
sub d_flush {
}

sub d_release {
}

sub d_fsync {
}

sub d_setxattr {
}

sub d_getxattr {
}

sub d_listxattr {
}

sub d_removexattr {
}

sub d_opendir {
}

sub d_readdir {
}

sub d_releasedir { 
}

sub d_fsyncdir {
}

sub d_init {
}

sub d_destroy {
}

sub d_access {
}

sub d_create {
}

sub d_ftruncate {
}

sub d_fgetattr {
}

sub d_lock {
}

sub d_utimens {
}

sub d_bmap {
}

sub d_ioctl {
}

sub d_poll {
}

#from http://perldoc.perl.org/perlipc.html#Complete-Dissociation-of-Child-from-Parent
sub daemonize {
	chdir(rootdir()) || die "can't chdir to /: $!";
	open(STDIN, '<', devnull()) || die "can't read /dev/null: $!";

	my $outfile;
	if($extraopts{'debug'}) {
		debug("Pid: $$");
		$outfile = catfile(tmpdir(), "dfshack$$");
	}
	else {
		$outfile = devnull();
	}
	open(STDOUT, '>', $outfile) || die "can't write to $outfile: $!";
	defined(my $pid = fork()) || die "can't fork: $!";
	exit if $pid; # non-zero now means I am the parent
	(setsid() != -1) || die "Can't start a new session: $!";
	open(STDERR, ">&STDOUT") || die "can't dup stdout: $!";
}

sub is_mounted {
	debug("checkmounts");
	if((stat($mountpoint))[0] == (stat(File::Spec->catdir($mountpoint, '..')))[0]) {
		debug("checkmounts: not mounted");
		return undef;
	}
	else {
		debug("checkmounts: $mountpoint already mounted");
		return 1;
	}
}

$dfsmount = shift(@ARGV) if (!$dfsmount && @ARGV);
$mountpoint = shift(@ARGV) if (!$mountpoint && @ARGV);

if(! -e "$mountpoint") {
	die "ERROR: attempted to mount to nonexistent directory $mountpoint\n";
	return -ENOTDIR();
}

if(! -e $dfsmount ) {
	die "Invalid dfs mount point $dfsmount\n";
}

if(! -d $dfsmount ) {
	die "dfs mount $dfsmount is not a directory.\n";
}

is_mounted() and die "$mountpoint is already mounted!\n";

$extraopts{'debug'} or daemonize();

if(! -d fixup($datadir)) {
	mkdir(fixup($datadir), 0777);
}

$dbh = db_connect();
db_create();

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

db_disconnect($dbh);

