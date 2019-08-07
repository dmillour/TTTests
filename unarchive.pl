use strict;
use warnings;
use feature 'say';
use Data::Dumper;
use Digest::file qw(digest_file_hex);
use Data::TreeDumper;

my $source_folderpath = './input';
my $tmp_folderpath    = './tmp';
my $dst_folderpath    = './output';

my $catalog_path        = './catalog.db';
my $catalog_ref         = {};
my @legal_archive_names = ('zip', 'rar');


sub unarchive {
   my ($filename, $extention) = @_;
   mkdir "$tmp_folderpath/$filename";
   my %unarchivers = ('zip' => "7z -y -o$tmp_folderpath/$filename x $source_folderpath/$filename");
   system($unarchivers{$extention});
}


sub scan_sourcefolder {
   opendir(my $source_folderfh, $source_folderpath) or die "unable to open '$source_folderpath' $!";
   while (my $filename = readdir $source_folderfh) {
      next if $filename =~ /^\./ or -d "$source_folderpath/$filename";
      if ($filename =~ /\.(\w+)$/) {
         my $extention = lc $1;
         next unless grep { $extention eq $_ } @legal_archive_names;
         unarchive($filename, $extention);
         print DumpTree(add($filename));
      }

   }
   close($source_folderfh);
}

sub add {
   my ($filename, $results) = @_;
   $results = {} unless defined $results;
   my $file_path = "$tmp_folderpath/$filename";
   if (-d $file_path) {
      opendir(my $tmpfh, $file_path) or die "unable to open '$file_path' $!";
      while (my $subfilename = readdir $tmpfh) {
         next if $subfilename =~ /^\./;
         $results = {%$results,%{add("$filename/$subfilename",$results)}};
      }
   }
   else {
       $results->{digest_file_hex( $file_path, 'MD5' )}=$filename;

   }
   return $results;
}

scan_sourcefolder();
