# Copyright (C) 2014 Catalyst IT Ltd (http://www.catalyst.net.nz)
#
# This file is distributed under the same terms as tks itself.
package TKS::Table;

use strict;
use warnings;

# $in     - raw html string
# $width  - max width in characters
# $height - max height in characters
sub html2text {

    my ($in, $maxwidth, $maxheight) = @_;

    # first parse into a 2d array

    my $row = -1;
    my $col = -1;
    my $maxCols = 0;

    my @data = [];

    $in =~ s/\n/ /g;
    $in =~ s/<td/\n<td/g;
    $in =~ s/<tr/\n<tr/g;
    $in =~ s/<th/\n<th/g;

    my @lines = split("\n", $in);
    foreach my $line (@lines){
        if ($line =~ /<table/){
            $row = -1;
            $col = -1;
        }
        if ($line =~ /<tr/){
            $row++;
            $col = -1;
            $data[$row] = [];
        }
        if ($line =~ /<t[h|d]/){
            $col++;
            if ($col > $maxCols){ $maxCols = $col; }
            my $val = $line;
            $val =~ s/<.*?\/?>//g;
            $val =~ s/&nbsp;/ /g;
            $val =~ s/^\s+//g;
            $val =~ s/\s+$//g;
            # print "$row, $col:  $val=\n";

            # Hack for nice hours formatting
            if ($val =~ /\d+\.\d+/){
                $val = sprintf('%.2f', $val * 1);
                $val = sprintf('%7s', $val);
            } elsif ($val =~ /^\d+$/){
                $val .= '   ';
                $val = sprintf('%7s', $val);
            }
            $data[$row][$col] = $val;
        }

    }

    if($#data == 0){
        return '';
    }
    my $suffix = '';
    if ($#data > $maxheight){
        $suffix = "# Only showing ".($maxheight-1)." out of $#data rows\n";
        @data = @data[0..$maxheight];
    }

    my @mean;
    my @vars;

    # Now for each column calculate a mean and a variance
    for(my $c=0; $c<=$maxCols; $c++){
        my $sum = 0;
        for(my $r=1; $r<$#data; $r++){
            $sum += length $data[$r][$c];
        }
        my $mean = $sum / ($#data-1);
        $mean[$c] = $mean;

        my $var = 0;
        for(my $r=1; $r<$#data; $r++){
            $var += ($mean - length $data[$r][$c]) ** 2;
        }
        $var = $var / ($#data-1);
        $var = $var ** .5;
        $vars[$c] = $var;
        # print "$c $data[0][$c] sum = $sum,   $mean,   $var \n";
    }

    my $width = 0;
    my $var;
    my $shown = $#mean+2; # how many columns will be shown, ideally all
    my $gutter = $maxwidth < 100 ? ' ' : '  ';
    my $prefix = '# ';

    # First tune # of columns, we want at least mean + 1 std of width for each col, if not remove a col
    do {
        $shown--;
        #$var = (length($prefix) + ($shown-1) * length($gutter) + sum(mean) - $maxwidth) / sum(vars);
        my $summean = 0;
        my $sumvars = 0;
        for(my $c=0; $c<$shown; $c++){
            $summean += $mean[$c];
            $sumvars += $vars[$c];
        }
        # This calculates how many std's we can show inside this width
        $var = -((length($prefix) + ($shown-1) * length($gutter) + $summean) - $maxwidth) / $sumvars;
        my $width = length($prefix) + ($shown-1) * length($gutter) + $summean + $sumvars * $var;
        # print "TUNING Cols: $shown -> dMean: $summean sumVar $sumvars vars $var (calc $width)  \n";

    } until ($var > .3); # .3 is a tuned magic number, smaller means more columns with less in them

    my @widths;
    for(my $c=0; $c<$shown; $c++){
        $widths[$c] = $mean[$c] + $vars[$c] * $var;
    }

    my $text = '';


    # This handles nicer formatting for ellipses on long strings
    # and also does a bit of magic with numbers
    sub crop {
        my ($str, $w, $ell) = @_;
        if (length($str) > $w){
            if ($ell){
                $str = substr($str, 0, $w-2).'..';
                return sprintf("%-".$w."s", $str);
            } else {
                $str = substr($str, 0, $w);
                return sprintf("%-".$w."s", $str);
            }
        }
        return sprintf("%-".$w."s", $str);
    }

    # print headers
    $text .= $prefix;
    for(my $c=0; $c<$shown; $c++){
        $text .= $gutter if $c != 0;
        $text .= crop($data[0][$c], $widths[$c],0);
    }
    $text .= "\n";

    $text .= $prefix;
    for(my $c=0; $c<$shown; $c++){
        $text .= $gutter if $c != 0;
        $text .= '-' x $widths[$c];
    }
    $text .= "\n";

    for(my $r=1; $r<$#data; $r++){
        $text .= $prefix;
        for(my $c=0; $c<$shown; $c++){
            $text .= $gutter if $c != 0;
            $text .= crop($data[$r][$c], $widths[$c],1);
        }
        $text .= "\n";
    }
    return $text.$suffix;

}

1;
