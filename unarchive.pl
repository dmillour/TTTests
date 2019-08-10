use strict;
use warnings;
use feature 'say';
use Tk;
use Tk::PNG;
use Tk::JPEG;
use Data::Dumper;
use Tk::Canvas;
use File::Spec;
use Digest::file qw(digest_file_hex);
use Storable;
use File::Path qw(make_path remove_tree);
use Data::TreeDumper;
use MIME::Types;

use Image::Resize;
use MIME::Base64;
use threads;
use Thread::Queue;


my $source_folderpath = './input';
my $tmp_folderpath    = './tmp';
my $dst_folderpath    = './output';
my $buffer_size = 7 ;

my $catalog_path        = './catalog.db';
my $catalog_ref         = {accepted => {}, rejected => {}, archives => {}};
my @legal_archive_names = ('zip', 'rar');
my $mt = MIME::Types->new();


sub unarchive {
   my ($filename, $extention) = @_;
   my $dest_tmp_folderpath = File::Spec->catdir($tmp_folderpath,    $filename);
   my $src_archivepath     = File::Spec->catdir($source_folderpath, $filename);
   mkdir $dest_tmp_folderpath;
   my %unarchivers = (
      'zip' => "7z -y -o$dest_tmp_folderpath x $src_archivepath",
      'rar' => "7z -y -o$dest_tmp_folderpath x $src_archivepath",
      '7z' => "7z -y -o$dest_tmp_folderpath x $src_archivepath",
   );
   system($unarchivers{$extention});
   return $dest_tmp_folderpath;
}


sub scan_sourcefolder {
   opendir(my $source_folderfh, $source_folderpath) or die "unable to open '$source_folderpath' $!";
   while (my $filename = readdir $source_folderfh) {
      my $filepath = File::Spec->catdir($source_folderpath, $filename);
      next if $filename =~ /^\./ or -d $filepath;
      next if exists $catalog_ref->{archives}{$filename} and not $catalog_ref->{archives}{$filename};
      if ($filename =~ /\.(\w+)$/) {
         my $extention = lc $1;
         next unless grep { $extention eq $_ } @legal_archive_names;
         my $dest_tmp_folderpath = unarchive($filename, $extention);
         my $filehash_ref        = add($filename);
         if ($catalog_ref->{archives}{$filename} = keys %$filehash_ref) {
            swipe($filehash_ref, $filename);
            move($filehash_ref, $filename);
         }
         remove_tree($dest_tmp_folderpath);
         store($catalog_ref, $catalog_path);
      }
   }
   close($source_folderfh);
}

sub add {
   my ($filename, $results) = @_;
   $results = {} unless defined $results;
   my $file_path = File::Spec->catdir($tmp_folderpath, $filename);
   if (-d $file_path) {
      opendir(my $tmpfh, $file_path) or die "unable to open '$file_path' $!";
      while (my $subfilename = readdir $tmpfh) {
         next if $subfilename =~ /^\./;
         $results = {%$results, %{add(File::Spec->catfile($filename, $subfilename), $results)}};
      }
   }
   else {
      return $results unless $mt->mimeTypeOf($file_path) =~ /^image/;
      my $hash = digest_file_hex($file_path, 'SHA1');
      unless (exists $catalog_ref->{accepted}{$hash} or exists $catalog_ref->{rejected}{$hash}) {
         $results->{$hash} = $filename;
      }
   }
   return $results;
}

sub move {
   my ($filehash_ref, $filename) = @_;
   for my $hash (keys %$filehash_ref) {
      my $src_filepath = File::Spec->catfile($tmp_folderpath, $filehash_ref->{$hash});
      my $dst_filepath = File::Spec->catfile($dst_folderpath, rename_dest_files(File::Spec->abs2rel($filehash_ref->{$hash}, $filename)));
      say "copying source:'$src_filepath' \tto '$dst_filepath'";
      $dst_filepath = check_dest($dst_filepath);
      my ($volume, $dirs) = File::Spec->splitpath($dst_filepath);
      make_path($dirs);
      rename $src_filepath, $dst_filepath;
      $catalog_ref->{accepted}{$hash} = $dst_filepath;
   }
}

sub rename_dest_files {
   my ($filename) = @_;
   $filename =~ s/ /_/g;
   $filename = lc $filename;
   return $filename;
}

sub check_dest {
   my ($dst_filepath) = @_;
   if (-f $dst_filepath and $dst_filepath =~ /(.+)(\.\w+)$/) {
      my $i = 1;
      $dst_filepath = $1 . "[$i]" . $2;
      while (-f $dst_filepath and $dst_filepath =~ /(.+)\[\d+\](\.\w+)$/ and $i < 1000) {
         $dst_filepath = $1 . "[$i]" . $2;
         $i++;
      }
      say "\t\t destination exists => $dst_filepath";
   }
   return $dst_filepath;
}

sub swipe {
   my ($filehash_ref, $filename) = @_;
   my @to_sort = sort { $a->[1] cmp $b->[1] } map { [$_, $filehash_ref->{$_}, 0] } keys %$filehash_ref;


   my $mw = MainWindow->new;
   my %max;
   $max{x} = $mw->screenwidth;
   $max{y} = $mw->screenheight;
   my @items;
   my $i     = 0;
   my $i_ref = \$i;


   $mw->geometry("$max{x}x$max{y}");
   my $frame  = $mw->Frame(-background => 'black')->pack(-expand => 1, -fill => "both");
   my $canvas = $frame->Canvas()->pack(-expand => 1, -fill => "both");

   my $queue_in = Thread::Queue->new();
   my $queue_out = Thread::Queue->new();

   my $producepic_sub = sub {
     while ( defined (my $i = $queue_in->dequeue())){
       say "dequeue $i";
       last if ( $i < 0);
       my $file = File::Spec->catfile($tmp_folderpath, $to_sort[$i][1]);
       my $im = Image::Resize->new($file);
       my $gd = $im->resize($max{x}, $max{y});
       #Tk needs base64 encoded image files
       $queue_out->enqueue([$i,encode_base64($gd->png)]);

     }
     threads->detach();
     threads->exit();
   };

   my $loadpic_sub = sub {
       my $i = $$i_ref > 0 ? $$i_ref-1 : 0 ;
       my $j = $$i_ref + $buffer_size < $#to_sort ? $$i_ref + $buffer_size : $#to_sort ;
       for my $k ($i..$j){
         unless ( exists $to_sort[$k][3] and $to_sort[$k][3]) {
           $queue_in->enqueue($k);
           $to_sort[$k][3] = 1;
         }
       }
       if ($i > 0 ) {
         delete $to_sort[$i][4];
       }
       while (defined(my $item_ref = $queue_out->dequeue_nb())) {
         $to_sort[$item_ref->[0]][4] = $item_ref->[1];
       }
       while (not exists $to_sort[$$i_ref][4]) {
         my $item_ref = $queue_out->dequeue();
         $to_sort[$item_ref->[0]][4] = $item_ref->[1];
       }
     };


  my $t = threads->create($producepic_sub);


   my $update_sub = sub {
       &$loadpic_sub();
      $mw->title("$filename ($$i_ref/$#to_sort) : $to_sort[$$i_ref][1]");
      $canvas->delete(@items);
      $items[0] = $canvas->createRectangle(0,           0, $max{x} / 2, $max{y}, -fill => "red");
      $items[1] = $canvas->createRectangle($max{x} / 2, 0, $max{x},     $max{y}, -fill => "green");
      my $image = $canvas->Photo(-data => $to_sort[$$i_ref][4], -format => 'png');
      $items[2] = $canvas->createImage($max{x} / 2 + $max{x} / 2 * $to_sort[$$i_ref][2], $max{y} / 2, -image => $image);
   };

   my $goright_sub = sub {
      $canvas->move($items[2], $max{x} / 2, 0);
      $to_sort[$$i_ref][2]++ if $to_sort[$$i_ref][2] < 1;
   };

   my $goleft_sub = sub {
      $canvas->move($items[2], -$max{x} / 2, 0);
      $to_sort[$$i_ref][2]-- if $to_sort[$$i_ref][2] > -1;
   };

   my $goup_sub = sub {
      if ($$i_ref > 1) {
         $$i_ref--;
         &$update_sub();
      }
   };
   my $godown_sub = sub {
      if ($$i_ref < $#to_sort) {
         $$i_ref++;
         &$update_sub();
      }
   };

   my $execution_sub = sub {
     for my $i ($$i_ref..$#to_sort) {
        $to_sort[$i][2] = -1;
     }
     $mw->destroy();
   };

   my $resize_sub = sub {
      if ($mw->geometry() =~ /^(\d+)x(\d+)/) {
         $max{x} = $1;
         $max{y} = $2;
      }
      &$update_sub();
   };


   $mw->bind('<KeyPress-d>',   $goright_sub);
   $mw->bind('<KeyRelease-d>', $godown_sub);
   $mw->bind('<KeyPress-a>',   $goleft_sub);
   $mw->bind('<KeyRelease-a>', $godown_sub);
   $mw->bind('<KeyPress-r>',   $resize_sub);
   $mw->bind('<KeyRelease-w>', $goup_sub);
   $mw->bind('<KeyRelease-s>', $godown_sub);
   $mw->bind('<KeyRelease-e>', $execution_sub);
   $mw->bind('<KeyRelease-q>', sub { $mw->destroy()});

   &$update_sub();

   MainLoop;
   $queue_in->enqueue(-1);


   #blacklist the rejected and whitelist the accepted
   for my $item_ref (@to_sort) {
      if ($item_ref->[2] == -1) {
         $catalog_ref->{rejected}{$item_ref->[0]} = $item_ref->[1];
         delete $filehash_ref->{$item_ref->[0]};
         $catalog_ref->{archives}{$filename}--;
      }
      elsif ($item_ref->[2] == 0) {
         delete $filehash_ref->{$item_ref->[0]};
      }
      elsif ($item_ref->[2] == 1) {
         $catalog_ref->{accepted}{$item_ref->[0]} = $item_ref->[1];
         $catalog_ref->{archives}{$filename}--;
      }

   }

   return $filehash_ref;
}


unless (-f $catalog_path) {
   store($catalog_ref, $catalog_path);
}

$catalog_ref = retrieve($catalog_path);

scan_sourcefolder();

store($catalog_ref, $catalog_path);


exit 0;
