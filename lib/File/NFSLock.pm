# -*- perl -*-
#
#  File::NFSLock - bdpO - NFS compatible (safe) locking utility
#  
#  $Id: NFSLock.pm,v 1.2 2001/05/25 05:53:37 rhandom Exp $
#  
#  Copyright (C) 2001, Paul T Seamons
#                      paul@seamons.com
#                      http://seamons.com/
#
#                      Rob B Brown
#                      rob@roobik.com
#  
#  This package may be distributed under the terms of either the
#  GNU General Public License 
#    or the
#  Perl Artistic License
#
#  All rights reserved.
#  
#  Please read the perldoc File::NFSLock
#
################################################################

package File::NFSLock;

use strict;
use Exporter ();
use vars qw(@ISA @EXPORT_OK $VERSION);

@ISA = qw(Exporter);
@EXPORT_OK = qw(uncache);

$VERSION = '1.00';

###----------------------------------------------------------------###

sub new ($$) {
  my $type  = shift;
  my $class = ref($type) || $type || __PACKAGE__;
  my $self  = {};
  $self->{file}      = shift;
  $self->{lock_file} = $self->{file} . '.NFSLock';
  $self->{lock_type} = shift;
  $self->{blocking_timeout} = shift || 0;
  
  die "Usage: my \$f = O::Lock->new('/pathtofile/file',
        'BLOCKING|BL|NONBLOCKING|NB|SHARED|SH', [timeout]);"
    unless length($self->{file})
      && $self->{lock_type} =~ /^((NON)?BLOCKING|NB|BL|SH(ARED)?)$/;

  die "Shared Locks are not yet implemented (but soon)"
    if $self->{lock_type} =~ /^S/;
  
  $self->{local_file} = local_file( $self->{file} );

  ### open a local temporary file
  open_local_file( $self->{local_file} )
    or return undef;

  ### non blocking lock (return undef on failure)
  if( $self->{lock_type} =~ /^N/ ){
    do_lock( $self->{lock_file}, $self->{local_file} )
      or return undef;

  ### blocking lock, wait until it's done
  }else{
    do_lock_blocking( $self->{lock_file}, $self->{local_file}, $self->{blocking_timeout} )
      or return undef;

  }

  ### clear up the NFS cache
  uncache( $self->{file} );

  ### only do a bless object if everything is good till now
  bless $self, $class;
  return $self;
}

sub unlock ($) {
  shift()->DESTROY();
}

sub DESTROY {
  my $self = shift;
  unlink( $self->{local_file} ) if -e $self->{local_file};
  do_unlock( $self->{lock_file} );
}

###----------------------------------------------------------------###

# concepts for these routines were taken from Mail::Box which
# took the concepts from Mail::Folder


sub local_file ($) {
  my $lock_file = shift;
  return $lock_file .'.tmp.'. time()%10000 .'.'. $$ .'.'. int(rand()*10000);
}

sub open_local_file ($) {
  my $local_file = shift;
  open (_LOCK,">>$local_file") or return undef;
  print _LOCK "Pid [$$]\nHost [$ENV{HOSTNAME}]\nFile [$local_file]\n";
  close(_LOCK);
  return 1;
}

sub do_lock ($$) {
  my $lock_file  = shift;
  my $local_file = shift;

  ### try a hard link
  link( $local_file, $lock_file);

  ### did it work (two files pointing to local_file)
  my $success = ( (stat($local_file))[3] == 2 );
  unlink $local_file;

  return $success;
}

sub do_lock_blocking {
  my $lock_file  = shift;
  my $local_file = shift;
  my $timeout    = shift;
  my $start_time = $timeout ? time() : 0;

  while( ! do_lock( $lock_file, $local_file ) ){

    ### wait a moment
    sleep(1);

    ### but don't wait past the time out
    if( $timeout && (time() - $start_time) > $timeout ){
      return 0;
    }

    ### reopen the file
    open_local_file( $local_file ) or return undef;
  }

  return 1;
}

sub do_unlock ($) {
  my $lock_file = shift;
  return unlink($lock_file);
}

sub uncache ($;$) {
  shift() if ref($_[0]);  # allow as method call
  my $file       = shift;
  my $local_file = local_file( $file );

  ### hard link to the actual file which will bring it up to date
  return ( link($file, $local_file) && unlink($local_file) );
}

1;


=head1 NAME 

File::NFSLock - perl module to do NFS (or not) locking

=head1 SYNOPSIS

  use File::NFSLock (uncache);

  my $file = "somefile";

  ### set up a lock - lasts until object looses scope
  if( defined(my $lock = File::NFSLock->new($file,"NONBLOCKING")) ){
    
    ### do write protected stuff on $file
    ### at this point $file is uncached from NFS (most recent)
    open(FILE, "+<$file") || die $!;

    ### or open it any way you like
    ### my $fh = IO::File->open( $file, 'w' ) || die $!

    ### update (uncache across NFS) other files
    uncache("someotherfile1");
    uncache("someotherfile2");
    # open(FILE2,"someotherfile1");

    ### unlock it
    $lock->unlock();
    ### OR
    ### undef $lock;
    ### OR let $lock go out of scope
  }


=head1 DESCRIPTION

Program based of concept of hard linking of files being atomic across
NFS.  This concept was mentioned in Mail::Box::Locker (which was
originally presented in Mail::Folder::Maildir).  Some routine flow is
taken from there -- particularly the idea of creating a random local
file, hard linking a common file to the local file, and then checking
the nlink status.  Some ideologies were not complete (uncache
mechanism, shared locking) and some coding was even incorrect (wrong
stat index).  File::NFSLock was written to be light, generic,
and fast.


=head1 USAGE

Locking occurs by creating a File::NFSLock object.  If the object
is created successfully, a lock is currently in place and remains in
place until the lock object goes out of scope (or calls the unlock
method).

A lock object is created by calling the new method and passing two 
or three parameters:

=over 4

=item Parameter 1: filename

Filename of the file upon which it is anticipated that a write will
happen to.  Locking will provide the most recent version (uncached)
of this file upon a successful file lock.

=item Parameter 2: lock type

Lock type must be one of the following:
 
  BLOCKING
  BL
  NONBLOCKING
  NB
  SHARED
  SH

Lock type determines whether the lock will be blocking, non blocking,
or shared.  Blocking locks will wait until other locks are removed
before the process continues.  Non blocking locks will return undef if
another process currently has the lock.  Shared will allow other
process to do a shared lock at the same time (shared is not yet
implemented).

=item Parameter 3: timeout (option)

Timeout is used in conjunction with a blocking timeout.  If specified,
File::NFSLock will block up to the number of seconds specified in
timeout before returning undef (could not get a lock).


=head1 TODO

Features yet to be implemented...

=over 4

=item SHARED locks

Need to allow for shared locking.  This will allow for safe
reading on files.  Underway.

=item Fnctl constants

Allow for passing of Fnctl constants rather than keywords.

=item Stale lock checking

Allow for easy view into whether a lock is stale or not.  Stale
locks can occur if process is "kill -9"ed during a lock.

=item Tests

Improve the test suite.

=back


=head1 AUTHORS

Paul T Seamons (paul@seamons.com) - Performed majority of the
programming with copious amounts of input from Rob Brown.

Rob B Brown (rob@roobik.com) - In addition to helping in the
programming, Rob Brown provided most of the core testing to make sure
implementation worked properly.

Also Mark Overmeer (mark@overmeer.net) - Author of Mail::Box::Locker,
from which some key concepts for File::NFSLock were taken.

Also Kevin Johnson (kjj@pobox.com) - Author of Mail::Folder::Maildir,
from which Mark Overmeer based Mail::Box::Locker.

=head1 COPYRIGHT

  Copyright (C) 2001, Paul T Seamons
                      paul@seamons.com
                      http://seamons.com/

                      Rob B Brown
                      rob@roobik.com
  
  This package may be distributed under the terms of either the
  GNU General Public License 
    or the
  Perl Artistic License

  All rights reserved.

=cut
