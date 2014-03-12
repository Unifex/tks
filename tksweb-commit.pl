#!/usr/bin/perl
 
use strict;
use warnings;
use autodie qw(:all);
use POSIX qw(strftime);
 
 
sub uploadToWrms {
    my ($dir, $date) = @_;
 
    system("tks -c $dir/$date.tks");
}
 
sub downloadFromTksweb {
    my ($dir, $date, $apikey) = @_;
 
    print "Committing for $date\n";
 
    my $url = "https://tksweb.catalyst.net.nz/export/catalyst/$date.tks";
    my $cmd = "wget -q -O - --post-data='api-key=$apikey' $url > $dir/$date.tks";
 
    system($cmd);
}
 
sub commitOneDay {
    my ($date) = @_;
 
    my $path = "$ENV{HOME}/tks";
    open(my $fh, "$path/api_key") || die "could not get api key";
    my $apikey = <$fh>;
    chomp($apikey);
    close($fh);
 
    downloadFromTksweb($path, $date, $apikey);
    uploadToWrms($path, $date);
}
 
sub formatDate {
    my ($time) = @_;
 
    my @localtime = localtime($time);
    my $str = strftime("%Y-%m-%d",@localtime);
}
 
sub tks_commit {
    my ($command, @args) = @_;
 
    my $now = time();
    my $today = formatDate($now);
 
    if ( ! $command ) {
        return commitOneDay($today);
    }
    if ( $command =~ m/week/ ) {
        for my $day ( 1 .. 7 ) {
            my $today = formatDate($now - ($day * 86400));
            commitOneDay($today);
        }
        return;
    }
    return commitOneDay($command);
}
 
tks_commit(@ARGV) unless caller;
