use strict;
use warnings;
use feature 'say';
use Tk;
use Tk::PNG;
use Tk::JPEG;
use Data::Dumper;
use Tk::Canvas;
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
   my %unarchivers = (
      'zip' => "7z -y -o$tmp_folderpath/$filename x $source_folderpath/$filename",
      'rar' => "7z -y -o$tmp_folderpath/$filename x $source_folderpath/$filename",
   );
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
         my $filehash_ref = add($filename);
         swipe($filehash_ref,$filename);
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
         $results = {%$results, %{add("$filename/$subfilename", $results)}};
      }
   }
   else {
      my $hash = digest_file_hex($file_path, 'SHA1');
      unless (exists $catalog_ref->{$hash}) {
         $results->{$hash} = $filename;
         $catalog_ref->{$hash} = $filename;
      }
   }
   return $results;
}

sub move {
   my ($filehash) = @_;
}

scan_sourcefolder();
print DumpTree($catalog_ref,'catalog');
sub swipe {
   my ($filehash_ref,$filename) = @_;
   my @to_sort = sort {$a->[1] cmp $b->[1]} map { [$_,$filehash_ref->{$_},0]} keys %$filehash_ref;



   my %max;
   $max{x} = 800;
   $max{y} = 600;
   my @items;
   my $i = 0;
   my $i_ref = \$i;

   my $mw = MainWindow->new;

   $mw->geometry("$max{x}x$max{y}");


   my $frame = $mw->Frame(-background => 'black')->pack(-expand => 1,-fill => "both");
   my $canvas = $frame->Canvas()->pack(-expand => 1,-fill => "both");
   push @items, $canvas->createRectangle(0,0,$max{x}/2,$max{y},-fill => "red");
   push @items, $canvas->createRectangle($max{x}/2,0,$max{x},$max{y},-fill => "green");

   my $update_sub = sub {
      my $file = "$tmp_folderpath/$to_sort[$$i_ref][1]";
      $mw->title($file);
      $canvas->delete(@items);
      $items[0] = $canvas->createRectangle(0,0,$max{x}/2,$max{y},-fill => "red");
      $items[1] = $canvas->createRectangle($max{x}/2,0,$max{x},$max{y},-fill => "green");
      my $image = $canvas->Photo(-file => $file );
      $items[2] = $canvas->createImage($max{x}/2+$max{x}/2*$to_sort[$$i_ref][2],$max{y}/2,-image => $image);

   };

   my $goright_sub = sub {
      $canvas->move($items[2],$max{x}/2,0);
      $to_sort[$$i_ref][2]++ if $to_sort[$$i_ref][2] < 1;
   };

   my $goleft_sub = sub {
      $canvas->move($items[2],-$max{x}/2,0);
      $to_sort[$$i_ref][2]-- if $to_sort[$$i_ref][2] > -1;
   };

   my $goup_sub = sub {
      say "go up $$i_ref";
      if ( $$i_ref > 1) {
         $$i_ref--;
         &$update_sub();
      }
   };
   my $godown_sub = sub {
      say "go down $$i_ref";
      if ( $$i_ref < $#to_sort) {
         $$i_ref++;
         &$update_sub();
      }
   };

   my $resize_sub = sub {
      if ( $mw->geometry() =~ /^(\d+)x(\d+)/ ) {
         $max{x} = $1;
         $max{y} = $2;
      }
      &$update_sub();
   };

   $mw->bind( '<KeyPress-d>', $goright_sub);
   $mw->bind( '<KeyRelease-d>', $godown_sub);
   $mw->bind( '<KeyPress-a>', $goleft_sub);
   $mw->bind( '<KeyRelease-a>', $godown_sub);
   $mw->bind( '<KeyPress-r>', $resize_sub);
   $mw->bind( '<KeyRelease-w>', $goup_sub);
   $mw->bind( '<KeyRelease-s>', $godown_sub);

   &$update_sub();

   MainLoop;
}
