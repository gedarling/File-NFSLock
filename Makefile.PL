use ExtUtils::MakeMaker;


my %args = (
            'NAME'	      => 'File::NFSLock',
            'VERSION_FROM'    => 'lib/File/NFSLock.pm',
            
            'PREREQ_PM'	      => {
            },
            
            dist              => {
              DIST_DEFAULT => 'all tardist',
              COMPRESS     => 'gzip -vf',
              SUFFIX       => '.gz',
            },
            
            clean             => {
              FILES        => '*~',
            },
            
            realclean         => {
              FILES        => '*~',
            },
            
            );

WriteMakefile(%args);

package MY;

sub libscan {
  my $self = shift;
  my $path = shift;
  ($path =~ / \bCVS\b | \~$ /x) ? undef : $path;
}

sub postamble {
  return qq^
    
pm_to_blib: README

README: lib/File/NFSLock.pm
\tpod2text lib/File/NFSLock.pm >README
  ^;
}

1;
