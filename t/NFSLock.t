BEGIN { $| = 1; print "1..4\n"; }


### load the module
END {print "not ok 1\n" unless $loaded;}
use File::NFSLock;
$loaded = 1;
print "ok 1\n";


### without forking, we can't really do much of
### a test.  For now, focus on whether hardlinking
### works on this system.


use POSIX qw(tmpnam);

### get a temporary name
my $tmp   = tmpnam();
my $local = File::NFSLock::local_file( $tmp );


if( File::NFSLock::open_local_file( $local ) ){
  print "ok 2\n";
}else{
  print "not ok 2\n";
}


if( File::NFSLock::do_lock( $tmp, $local ) ){
  print "ok 3\n";
}else{
  print "not ok 3\n";
}



if( File::NFSLock::do_unlock( $tmp ) ){
  print "ok 4\n";
}else{
  print "not ok 4\n";
}


