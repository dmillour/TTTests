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
use File::Path qw(make_path remove_tree);
use Data::TreeDumper;
use MIME::Types;
use File::Copy 'copy';

use Image::Resize;
use MIME::Base64;
use threads;
use Thread::Queue;
use BerkeleyDB;
use Getopt::Long;

use XML::Twig;

my $twig_ref = XML::Twig->new();
$twig_ref->parsefile('config.xml');
my $twig_root_ref = $twig_ref->root();


my $source_folderpath = $twig_root_ref->first_child('source')->text();
my $tmp_folderpath    = $twig_root_ref->first_child('tmp')->text();
my $dst_folderpath    = $twig_root_ref->first_child('dst')->text();
my $buffer_size_down  = $twig_root_ref->first_child('buffer_size_down')->text();
my $buffer_size_up    = $twig_root_ref->first_child('buffer_size_up')->text();
my $threads_nb        = $twig_root_ref->first_child('threads_nb')->text();

my %special_folders;
for my $folder_elem_ref ($twig_root_ref->descendants('folder')) {
   $special_folders{$folder_elem_ref->att('key')} = [$folder_elem_ref->att('title'), $folder_elem_ref->text()];
}


my %catalog_paths = (accepted => 'accepted.dbm', rejected => 'rejected.dbm', archives => 'archives.dbm');
my %catalog;


my @legal_archive_names = ('zip', 'rar', '7z');
my $mt                  = MIME::Types->new();

my $queue_in  = Thread::Queue->new();
my $queue_out = Thread::Queue->new();


#command line options
my $verbose = '';
my $rebuild = '';
GetOptions('verbose' => \$verbose, 'rebuild' => \$rebuild);


#DB funtions -- Begin
sub db_init {
   for my $recname (keys %catalog_paths) {
      say "load db :'$recname'";
      $catalog{$recname} = new BerkeleyDB::Hash(-Filename => $catalog_paths{$recname}, -Flags => DB_CREATE) or die "Cannot open file: '$catalog_paths{$recname}' $!";
   }
}

sub db_close {
   for my $recname (keys %catalog_paths) {
      say "close db :'$recname'";
      $catalog{$recname}->db_close();
   }
}

sub should_skip_archive {
   my ($filename) = @_;
   my $status = $catalog{archives}->db_exists($filename);
   if ($status) {
      return 0;
   }
   else {
      my $val;
      $status = $catalog{archives}->db_get($filename, $val);
      return not $val;
   }
}

sub set_archive_remains {
   my ($filename, $val) = @_;
   my $status = $catalog{archives}->db_put($filename, $val);
   if ($status) {
      die "unable seting in the archive db value :'$val' into '$filename' $!";
   }
}

sub is_file_known {
   my ($hash)  = @_;
   my $status1 = $catalog{accepted}->db_exists($hash);
   my $status2 = $catalog{rejected}->db_exists($hash);
   my $status  = $status1 && $status2;
   return not $status;
}

sub accept_file {
   my ($hash, $filename) = @_;
   my $status = $catalog{accepted}->db_put($hash, $filename);
   if ($status) {
      die "unable seting in the accepted db value :'$filename' into '$hash' $!";
   }
}

sub reject_file {
   my ($hash, $filename) = @_;
   my $status = $catalog{rejected}->db_put($hash, $filename);
   if ($status) {
      die "unable seting in the rejected db value :'$filename' into '$hash' $!";
   }
}

sub dump_dbs {
   my ($dbname) = @_;
   say "$dbname db:";
   my $cursor = $catalog{$dbname}->db_cursor();
   my $key    = '';
   my $val    = '';
   while ($cursor->c_get($key, $val, DB_NEXT) == 0) {
      print "\tKey: " . $key . ", value: " . $val . "\n";
   }
}

#DB funtions -- encoded

#worker job to cache the image rezizing
sub producepic {
   threads->detach();
   while (defined(my $item_ref = $queue_in->dequeue())) {
      my $index = $item_ref->[0];
      my $file  = $item_ref->[1];
      my $x     = $item_ref->[2];
      my $y     = $item_ref->[3];

      last unless -f $file;
      my $res;
      my $ok = 0;
      eval {
         my $im = Image::Resize->new($file);
         my $gd = $im->resize($x, $y);
         $res = encode_base64($gd->png);
         $ok  = 1;
      };

      #Tk needs base64 encoded image files
      $queue_out->enqueue([$index, $ok, $res]);
   }
}


sub scan_sourcefolder {
   opendir(my $source_folderfh, $source_folderpath) or die "unable to open '$source_folderpath' $!";
   while (my $filename = readdir $source_folderfh) {
      my $filepath = File::Spec->catdir($source_folderpath, $filename);
      next if $filename =~ /^\./ or -d $filepath;
      next if should_skip_archive($filename);
      if ($filename =~ /\.(\w+)$/) {
         my $extention = lc $1;
         next unless grep { $extention eq $_ } @legal_archive_names;
         my $dest_tmp_folderpath = unarchive($filename, $extention);
         my @files               = sort { $a->{filename} cmp $b->{filename} } add($filename, $tmp_folderpath);
         my $file_nb             = @files;
         set_archive_remains($filename, $file_nb);
         if ($file_nb) {
            @files = swipe($filename, @files);
            move($filename, @files);
         }
         remove_tree($dest_tmp_folderpath);
      }
   }
   close($source_folderfh);
}

sub scan_destfolder {
   my @files = add('.', $dst_folderpath);
   for my $item_ref (@files) {
      accept_file($item_ref->[0], $item_ref->[1]);
   }
}

sub unarchive {
   my ($filename, $extention) = @_;
   my $dest_tmp_folderpath = File::Spec->catdir($tmp_folderpath,    $filename);
   my $src_archivepath     = File::Spec->catdir($source_folderpath, $filename);
   mkdir $dest_tmp_folderpath;
   my %unarchivers = (
      'zip' => "7z -y -o$dest_tmp_folderpath x $src_archivepath > log.txt 2>&1",
      'rar' => "7z -y -o$dest_tmp_folderpath x $src_archivepath > log.txt 2>&1",
      '7z'  => "7z -y -o$dest_tmp_folderpath x $src_archivepath > log.txt 2>&1",
   );
   system($unarchivers{$extention});
   return $dest_tmp_folderpath;
}

sub add {
   my ($filename, $tmp_folderpath) = @_;
   my @results;
   my $file_path = File::Spec->catdir($tmp_folderpath, $filename);
   if (-d $file_path) {
      opendir(my $tmpfh, $file_path) or die "unable to open '$file_path' $!";
      while (my $subfilename = readdir $tmpfh) {
         next if $subfilename =~ /^\./;
         push @results, add(File::Spec->catfile($filename, $subfilename), $tmp_folderpath);
      }
   }
   else {
      return @results unless $mt->mimeTypeOf($file_path) =~ /^image/;
      my $hash = digest_file_hex($file_path, 'SHA1');
      unless (is_file_known($hash)) {
         push @results, {hash => $hash, filename => $filename, status => 0};
      }
   }
   return @results;
}

sub move {
   my ($filename, @files) = @_;
   for my $item_ref (@files) {
      my $src_filepath = File::Spec->catfile($tmp_folderpath, $item_ref->{filename});
      my $dst_filepath = File::Spec->catfile($dst_folderpath, rename_dest_files(File::Spec->abs2rel($item_ref->{filename}, $filename)));
      if ($item_ref->{special}) {
         my $special_folderpath = File::Spec->catdir($dst_folderpath, $special_folders{$item_ref->{special}}[1]);
         copy_special_file($src_filepath, $special_folderpath);
      }
      say "copying source:'$src_filepath' \tto '$dst_filepath'";
      $dst_filepath = check_dest($dst_filepath);
      my ($volume, $dirs) = File::Spec->splitpath($dst_filepath);
      make_path($dirs);
      rename $src_filepath, $dst_filepath;
      accept_file($item_ref->{hash}, $dst_filepath);
   }
}

sub rename_dest_files {
   my ($filename) = @_;
   $filename =~ s/ /_/g;
   $filename = lc $filename;
   return $filename;
}

sub copy_special_file {
   my ($filename, $dst_folder) = @_;
   make_path($dst_folder);
   if ($filename =~ /\.([^\.]+)$/) {
      my $ext          = lc $1;
      my $index        = get_special_index($dst_folder);
      my $dst_filepath = File::Spec->catfile($dst_folder, sprintf "%04d.%s", $index, $ext);
      say "special source '$filename'\tto '$dst_filepath'";
      copy($filename, $dst_filepath) or die "Copy failed: $!";
   }
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

sub get_special_index {
   my ($dst_folder) = @_;
   my $max = -1;
   opendir(my $dst_folderfh, $dst_folder) or die "unable to open '$dst_folder' $!";
   while (readdir $dst_folderfh) {
      if (/(\d+)\.\w+/) {
         $max = $max > $1 ? $max : $1;
      }
   }
   return $max + 1;
}

sub swipe {
   my ($filename, @to_sort) = @_;

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

   my $loadpic_sub = sub {
      my ($force) = @_;
      my $i = $$i_ref - $buffer_size_up > 0           ? $$i_ref - $buffer_size_up   : 0;
      my $j = $$i_ref + $buffer_size_down < $#to_sort ? $$i_ref + $buffer_size_down : $#to_sort;
      for my $k ($i .. $j) {
         if ($force) {
            delete $to_sort[$k]{resizing} if exists $to_sort[$k]{resizing};
            delete $to_sort[$k]{data}     if exists $to_sort[$k]{data};
            delete $to_sort[$k]{ok}       if exists $to_sort[$k]{ok};
         }
         unless (exists $to_sort[$k]{resizing} and $to_sort[$k]{resizing}) {
            $queue_in->enqueue([$k, File::Spec->catfile($tmp_folderpath, $to_sort[$k]{filename}), $max{x}, $max{y}]);
            $to_sort[$k]{resizing} = 1;
         }
      }
      if ($i - 1 >= 0 and exists $to_sort[$i - 1]{data}) {
         delete $to_sort[$i - 1]{resizing};
         delete $to_sort[$i - 1]{data};
         delete $to_sort[$i - 1]{ok};
      }
      while (defined(my $item_ref = $queue_out->dequeue_nb())) {
         my $index = $item_ref->[0];
         $to_sort[$index]{data}     = $item_ref->[2];
         $to_sort[$index]{ok}       = $item_ref->[1];
         $to_sort[$index]{resizing} = 0;

      }
      while (not exists $to_sort[$$i_ref]{data}) {
         my $item_ref = $queue_out->dequeue();
         my $index    = $item_ref->[0];
         $to_sort[$index]{data}     = $item_ref->[2];
         $to_sort[$index]{ok}       = $item_ref->[1];
         $to_sort[$index]{resizing} = 0;
      }
   };


   my $update_sub = sub {
      my ($force) = @_;
      &$loadpic_sub($force);

      # make the title of the Main Windows
      my $title = "$filename ($$i_ref/$#to_sort) : $to_sort[$$i_ref]{filename}";
      if (exists $to_sort[$$i_ref]{special} and $to_sort[$$i_ref]{special}) {
         $title .= " [" . $special_folders{$to_sort[$$i_ref]{special}}[0] . "]";
      }
      $mw->title($title);
      $canvas->delete(@items);
      $items[0] = $canvas->createRectangle(0,           0, $max{x} / 2, $max{y}, -fill => "red");
      $items[1] = $canvas->createRectangle($max{x} / 2, 0, $max{x},     $max{y}, -fill => "green");
      if ($to_sort[$$i_ref]{ok}) {
         my $image = $canvas->Photo(-data => $to_sort[$$i_ref]{data}, -format => 'png');
         $items[2] = $canvas->createImage($max{x} / 2 + $max{x} / 2 * $to_sort[$$i_ref]{status}, $max{y} / 2, -image => $image);
      }

   };

   my $goright_sub = sub {
      $canvas->move($items[2], $max{x} / 2, 0);
      $to_sort[$$i_ref]{status}++ if $to_sort[$$i_ref]{status} < 1;
   };

   my $goleft_sub = sub {
      $canvas->move($items[2], -$max{x} / 2, 0);
      $to_sort[$$i_ref]{status}-- if $to_sort[$$i_ref]{status} > -1;
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

   my $pass_sub = sub {
      if ($to_sort[$$i_ref]{status} != 0) {
         &$godown_sub();
      }
   };


   my $execution_sub = sub {
      for my $i ($$i_ref .. $#to_sort) {
         $to_sort[$i]{status} = -1;
      }
      $mw->destroy();
   };

   my $resize_sub = sub {
      if ($mw->geometry() =~ /^(\d+)x(\d+)/) {
         $max{x} = $1;
         $max{y} = $2;
      }
      &$update_sub(1);
   };

   my $special_sub_factory = sub {
      my ($key) = @_;
      return sub {
         $to_sort[$$i_ref]{special} = $key;
         &$update_sub();
      };
   };

   $mw->bind('<KeyPress-d>',   $goright_sub);
   $mw->bind('<KeyRelease-d>', $godown_sub);
   $mw->bind('<KeyPress-a>',   $goleft_sub);
   $mw->bind('<KeyRelease-a>', $godown_sub);
   $mw->bind('<KeyPress-r>',   $resize_sub);
   $mw->bind('<KeyRelease-w>', $goup_sub);
   $mw->bind('<KeyRelease-s>', $godown_sub);
   $mw->bind('<KeyRelease-e>', $execution_sub);
   $mw->bind('<KeyRelease-q>', sub { $mw->destroy() });

   for my $key (keys %special_folders) {
      $mw->bind("<KeyRelease-$key>", &$special_sub_factory($key));
   }

   &$update_sub();

   MainLoop;

   #blacklist the rejected and whitelist the accepted
   my @results;
   my $file_nb = 0;
   for my $item_ref (@to_sort) {
      if ($item_ref->{status} == -1) {
         reject_file($item_ref->{hash}, $item_ref->{filename});
      }
      elsif ($item_ref->{status} == 0) {
         $file_nb++;
      }
      elsif ($item_ref->{status} == 1) {
         push @results, $item_ref;
      }
   }
   set_archive_remains($filename, $file_nb);
   return @results;
}


#main

db_init();

#many worker
for (1 .. $threads_nb) {
   threads->create('producepic');
}
if ($rebuild) {
   scan_destfolder();
}
else {
   scan_sourcefolder();
}

if ($verbose) {
   dump_dbs('accepted');
   dump_dbs('rejected');
   dump_dbs('archives');
}

db_close();

exit 0;
