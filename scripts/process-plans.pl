#!/usr/bin/env perl

use strict;
use 5.14.1;

use Data::Dumper;
use FileHandle;
use Getopt::Long;

use File::Path;
use File::Path;
#use File::Copy;

use YAML;
use JSON;


###########################################################################
###########################################################################

our (
     %opts,				#hold command line parameters
     $VERSION,			#collected from CVS Revision
    );

$VERSION	 = 0.4; #sprintf ("%d.%03d", q$Revision$ =~ /(\d+)/g);

my %options_wanted = (
    flags               => [ qw (help|h debug verbose raw
                                ) ],
    flags_negatives     => [ qw () ],
    strings             => [ qw ( mode|m before after maxincome|x) ],
    strings_multiples   => [ qw () ],
    integers            => [ qw () ],
    integers_multiples  => [ qw () ],
);

GetOptions (\%opts,
            (map {  $_     } @{$options_wanted{flags}}),
            (map { "$_!"   } @{$options_wanted{flags_negatives}}),
            (map { "$_=s"  } @{$options_wanted{strings}}),
            (map { "$_=s@" } @{$options_wanted{strings_multiples}}),
            (map { "$_=i"  } @{$options_wanted{integers}}),
            (map { "$_=i@" } @{$options_wanted{integers_multiples}}),
           );

foreach my $opts_type (qw (strings_multiples integers_multiples)) {
    foreach my $opts_field (@{$options_wanted{$opts_type}}) {
        $opts{$opts_field} = [ split (',', join (',', @{$opts{$opts_field}})) ];
    }
}


###########################################################################

our %rate_details;
my @slices = (
			  ( map { $_ *     5000 } (  0 ..  20) ),
			  ( map { $_ *    10000 } ( 11 ..  30) ),
			  ( map { $_ *    50000 } (  6 ..  20) ),
			  ( map { $_ *   100000 } ( 11 ..  30) ),
			  ( map { $_ *  1000000 } (  4 ..  20) ),
			  ( map { $_ * 10000000 } (  3 ..  20) ),
			 );

our $rawjsondir = '../data/rawplans';
our $plansdir   = '../data/details';
our $displaydir = '../data/display';

our %vault;


###########################################################################
###########################################################################

sub _error {
    say "ERROR: $_[0]\nUse --help for help or --man for manual." and exit(1);
}

###########################################################################

sub _say {
    return unless $opts{verbose};
    say $_[0];
}

###########################################################################

sub _debug_messages {
    return unless $opts{debug};
    say for @_;
}

###########################################################################

sub slurp_file {
    my $filename = shift;
    local $/ = '';
    my $content;
    my $fh = FileHandle->new($filename, "r");
    if (defined $fh) {
        $content = <$fh>;
        undef $fh;       # automatically closes the file
    }
    else {
         _error ("There was a problem reading from '$filename'");
    }
    return ($content);
}

###########################################################################

sub open_writable_file
{
    my $filename = shift;
    my $fh = FileHandle->new($filename, "w");
    _error "Could not open $filename to write" unless (defined $fh);

    return ($fh);
}

###########################################################################

sub slurp_json
{
    my ($filename, $json) = @_;
    return ($json->decode (slurp_file ($filename)));
}

###########################################################################

sub dump_json
{
    my ($filename, $json, $data) = @_;

    my $fh = FileHandle->new($filename, "w");
    _error ("There was a problem reading from '$filename'") unless (defined $fh);

    print $fh $json->encode ($data);

    undef $fh;       # automatically closes the file
}

###########################################################################
###########################################################################

sub process_raw_to_usable
{
    _say 'entering process_raw_to_usable';
    opendir (DIR, $rawjsondir) or die "could not open $rawjsondir, $!";
    my @files = grep { /\.json/ } readdir DIR;
    closedir DIR;

    mkpath ($plansdir, 1, 0755);
    my $json = JSON->new->pretty ();

    foreach my $planfile (@files) {
        _say ("   now on $planfile");
        my $data = slurp_json ("$rawjsondir/$planfile", $json);
        if ($data->{plan_type} eq 'stepped') {
            process_raw_to_usable_stepped ($data);
        }
        elsif ($data->{plan_type} eq 'slanted') {
            process_raw_to_usable_slanted ($data);
        }
        dump_json ("$plansdir/$planfile", $json, $data);
    }
}

###########################################################################
###########################################################################

sub process_raw_to_usable_stepped
{
    my $data = shift;

    my @rates_in = @{$data->{raw_rates}};

    #do start of first step and declarations to get setup
    my $top = shift (@rates_in);
    my ($low, $rate) = @{$top};
    my $running_total = 0;
    my %inflection_points;
    $inflection_points{$low}++;
    my @layers;

    #loop through steps
    foreach my $row (@rates_in) {
        my ($high, $nextrate) = @{$row};

        my $margin = $high - $low;
        my $base = $margin * $rate / 100;
        $inflection_points{$high}++;

        push (@layers,
              { low             => $low,
                high            => $high,
                margin          => $margin,
                running_total   => $running_total,
                rate            => $rate,
              }
        );

        $running_total += $base;
        $low            = $high;
        $rate           = $nextrate;
    }

    #set final step to infinity
    push (@layers,
          { low             => $low,
            high            => 'top',
            margin          => '-',
            running_total   => $running_total,
            rate            => $rate,
          }
    );

    #save answers
    $data->{calculatable} = [ reverse @layers ];
    $data->{inflections} = [ sort { $a <=> $b } keys %inflection_points ];
}

###########################################################################
###########################################################################

#take low X & Y and high X & Y to calculate slope
sub calculate_slope
{
	my ($lowX, $lowY, $highX, $highY) = @_;
    return ( ($highY - $lowY) / ($highX - $lowX) );
}

#take high X & Y with slope, return low Y (low X is 0 by definition)
sub calculate_zero_rate
{
	my ($highX, $highY, $slope) = @_;
	return ( $highY - ($highX * $slope ) );
}

sub calculate_max_rate
{
	my ($X, $slope, $base) = @_;
	return ( ($X * $slope) + $base );
}

sub calculate_max_point
{
	my ($lowY, $highY, $slope) = @_;
	return ( ($highY - $lowY) / $slope);
}

sub calculate_fullslant
{
	my ($lowY, $highX, $slope) = @_;
	my $rate = ($highX * $slope) + $lowY;
	return ( $highX * $rate / 100 );
}

# the standard points plus any inflection points from selected plans
sub combine_inflection_points
{
    my (@selected_plans) = @_;

    my %points = ( map { $_ => 1 } @slices );
    foreach my $plan ( @selected_plans ) {
        foreach ( @{$plan->{inflections}} ) {
            $points{$_} += 1;
        }
    }

    return ( sort { $a <=> $b } keys %points );
}

###########################################################################

sub process_raw_to_usable_slanted
{
    my $data = shift;

    my %details = ( %{$data->{raw_rates}} );
    my %inflection_points = map { $details{$_} => 1 } (qw (lowpoint highpoint));

    $details{marginal_slope}    = calculate_slope ($details{lowpoint},  $details{lowrate},
                                                    $details{highpoint}, $details{highrate});
    $details{real_slope}        = $details{marginal_slope} / 2;
    $details{fullslant}         = calculate_fullslant ($details{lowrate}, $details{highpoint}, $details{real_slope});

    _say ("slant calculations are" . Dumper (\%details));
    $data->{calculatable}   = \%details;
    $data->{inflections}    = [ sort { $a <=> $b } keys %inflection_points ];
}

###########################################################################
###########################################################################

sub amount_due
{
	my ($plan, $income) = @_;

    return ($plan->{due}{$income}) if (exists $plan->{due}{$income});

	if ($plan->{plan_type} eq 'stepped') {
		$plan->{due}{$income} = stepped_plan ($plan, $income);
	}
    elsif ($plan->{plan_type} eq 'slanted') {
		$plan->{due}{$income} = slanted_plan ($plan, $income);
	}

    return ($plan->{due}{$income});
}

###########################################################################

sub stepped_plan
{
	my ($plan, $income) = @_;

    my $layers = $plan->{calculatable};

	foreach my $row (@{$layers}) {
		if ($income > $row->{low}) {
			my $tax = ($row->{rate} / 100 * ($income - $row->{low})) + $row->{running_total};
			my $effective_rate = $tax / $income * 100;
			return ( [ $tax, $effective_rate, $row->{rate} ] );
		}
	}
	return ( [ 0, $layers->[-1]{rate}, $layers->[-1]{rate} ] );
}

###########################################################################

sub slanted_plan
{
	my ($plan, $income) = @_;

    my ($tax, $marginal_rate);
    my $details = $plan->{calculatable};

    if ($income > $details->{highpoint}) {
		$tax = ($details->{highrate} * ($income - $details->{highpoint}) / 100) + $details->{fullslant};
		$marginal_rate = $details->{highrate};
	}
    else {
		$tax = ( $income * ($income * $details->{real_slope}     + $details->{lowrate} ) / 100 );
		$marginal_rate =   ($income * $details->{marginal_slope} + $details->{lowrate} );
	}
	my $effective_rate = ($income > 0) ? $tax / $income * 100 : $details->{lowrate};
	return ( [ $tax, $effective_rate, $marginal_rate ] );
}

###########################################################################
###########################################################################

sub top_nav_home
{
    return (qq~<a href="/index.html">Home</a>~);
}

sub top_nav_plans
{
    return (qq~ -&gt; <a href="/data/display/index.html">Plans</a>~);
}

sub top_nav_plan
{
    my $planname = shift;
    return (qq~ -&gt; <a href="../index.html">$planname</a>~);
}

###########################################################################
###########################################################################

sub print_display_top
{
    my ($fh, $data) = @_;

    my $name = $data->{plan_name};

    print $fh join ("\n",
        '<html>',
        '<head>',
        "<title>$data->{plan_name}</title>",
        '</head>',
        '<body>',
        top_nav_home (),
        top_nav_plans (),
        '<hr>',
        "<h1>Details of taxplan: $data->{plan_name}</h1>",
        '',
    );

}

###########################################################################

sub print_compare_top
{
    my ($fh, $dataA, $dataB) = @_;

    print $fh join ("\n",
        '<html>',
        '<head>',
        "<title>$dataA->{plan_name} vs $dataB->{plan_name}</title>",
        '</head>',
        '<body>',
        top_nav_home (),
        top_nav_plans (),
        top_nav_plan ($dataA->{plan_name}),
        '<hr>',
        "<h1>Comparison of taxplans: $dataA->{plan_name} vs $dataB->{plan_name}</h1>",
        '',
    );

}

###########################################################################

sub print_index_top
{
    my ($fh) = @_;

    print $fh join ("\n",
        '<html>',
        '<head>',
        "<title>Tax Plans</title>",
        '</head>',
        '<body>',
        top_nav_home (),
        '<hr>',
        "<h1>Tax Plans</h1>",
        '<table>',
        "<tr><th>Plan</th><th>Type</th><th>Description</th></tr>",
        '',
    );

}

###########################################################################

sub print_display_stepped
{
    my ($fh, $data) = @_;

    print $fh join ("\n",
        '<table>',
        '<tr>',
        ( map { "<th>$_</th>" } ("From", "To", "Marginal Rate", "Total", "Rate")),
        '</tr>',
        '',
    );
    foreach my $row (reverse @{$data->{calculatable}}) {
        print $fh join ("\n",
            '<tr>',
            ( map { "<td>$row->{$_}</td>" } qw (low high margin running_total rate) ),
            '</tr>',
            '',
        );
    }
    print $fh join ("\n",
        '</table>',
        '',
    );

}

###########################################################################

sub print_display_slanted
{
    my ($fh, $data) = @_;

    print $fh join ("\n",
        '<h3>Temporary description</h3>',
        '<pre>',
        Dumper ($data->{calculatable}),
        '</pre>',
        '',
    );
}

###########################################################################

sub quickformat_percent     { return sprintf ("%7.2f\%",  shift); }
sub quickformat_dollars     { return sprintf ("\$%12.2f", shift); }

sub print_compare_numbers
{
    my ($fh, $dataA, $dataB) = @_;

    my @incomes = combine_inflection_points ($dataA, $dataB);
    my @rows;   #table version
    #my $svg;    #graphical version

    foreach my $income (@incomes) {

        my $valuesA = amount_due ($dataA, $income);
        my $valuesB = amount_due ($dataB, $income);
        push (@rows, join ("\n",
            '<tr>',
            ( map { "<td>$_</td>" }
                quickformat_dollars ($income),

                quickformat_dollars ($valuesA->[0]),
                quickformat_percent ($valuesA->[1]),
                quickformat_percent ($valuesA->[2]),

                quickformat_dollars ($valuesB->[0]),
                quickformat_percent ($valuesB->[1]),
                quickformat_percent ($valuesB->[2]),

                quickformat_percent (($valuesB->[0])
                                     ? ( ($valuesB->[0] - $valuesA->[0]) / $valuesB->[0] * 100)
                                     : 0
                                    ),
            ),
            '</tr>',
            '',
        ));
    }

print $fh <<EOF;
<table>
<tr>
   <th rowspan="2">Income</th>
   <th colspan="3">First Plan</th>
   <th colspan="3">Second Plan</th>
   <th rowspan="2">Change</th>
</tr>
<tr>
   <th>Tax Due</th><th>Effective Rate</th><th>Marginal Rate</th>
   <th>Tax Due</th><th>Effective Rate</th><th>Marginal Rate</th>
</tr>

EOF

    print $fh join ("\n",
        @rows,
        '</table>',
        '',
    );

}

###########################################################################

sub print_index_plan
{
    my ($fh, $data) = @_;

    print $fh join ("\n",
        '<tr><td>',
        "<a href='$data->{plan_name}/index.html'>$data->{plan_name}</a>",
        '</td><td>',
        $data->{plan_type} || '&nbsp;',
        '</td><td>',
        $data->{description} || '&nbsp;',
        '</td></tr>',
        '',
    );
}

###########################################################################

sub print_display_bottom
{
    my ($fh, $data) = @_;

print $fh <<EOF;
</body>
</html>

EOF
}

###########################################################################

sub print_compare_bottom
{
    my ($fh, $dataA, $dataB) = @_;

print $fh <<EOF;
</body>
</html>

EOF
}

###########################################################################

sub print_index_bottom
{
    my ($fh) = @_;

print $fh <<EOF;
</table>
</body>
</html>

EOF
}

###########################################################################

sub document_plans
{
    _say 'entering document_plans';

    mkpath ("$displaydir", 1, 0755);
    my $fhi = open_writable_file ("$displaydir/index.html");

    print_index_top     ($fhi);

    #----------------------------------------------------------------------

    foreach my $planname (@{$vault{planlist}}) {
        mkpath ("$displaydir/$planname", 1, 0755);

        print_index_plan    ($fhi, $vault{data}{$planname});

        #------------------------------------------------------------------

        my $fhp = open_writable_file ("$displaydir/$planname/index.html");

        print_display_top           ($fhp, $vault{data}{$planname});
        if ($vault{data}{$planname}{plan_type} eq 'stepped') {
            _say "$planname is stepped";
            print_display_stepped   ($fhp, $vault{data}{$planname});
        }
        elsif ($vault{data}{$planname}{plan_type} eq 'slanted') {
            print_display_slanted   ($fhp, $vault{data}{$planname});
        }
        print_display_bottom        ($fhp, $vault{data}{$planname});

        undef $fhp;       # automatically closes the file
        
        #------------------------------------------------------------------

        foreach my $othername (@{$vault{planlist}}) {
            next if ($planname eq $othername); #don't compare to ourself

            my $fho = open_writable_file ("$displaydir/$planname/$othername.html");

            print_compare_top     ($fho, $vault{data}{$planname}, $vault{data}{$othername});
            print_compare_numbers ($fho, $vault{data}{$planname}, $vault{data}{$othername});
            print_compare_bottom  ($fho, $vault{data}{$planname}, $vault{data}{$othername});

            undef $fho;       # automatically closes the file
        }

        #------------------------------------------------------------------
    }

    #----------------------------------------------------------------------

    print_index_bottom  ($fhi);
    undef $fhi;       # automatically closes the file
}

###########################################################################
#DEPRICATED

sub process_usable_to_display
{
    _say 'entering process_usable_to_display';
    opendir (DIR, $plansdir) or die "could not open $plansdir, $!";
    my @files = grep { /\.json/ } readdir DIR;
    closedir DIR;

    mkpath ($displaydir, 1, 0755);
    my $json = JSON->new->pretty ();

    foreach my $planfile (@files) {
        _say ("   now on $planfile");
        my $data    = slurp_json ("$plansdir/$planfile", $json);
        my $htmlfile   = $planfile;
        $htmlfile  =~ s/\.json$/.html/;
        my $fh      = open_writable_file ("$displaydir/$htmlfile");

        print_display_top     ($fh, $data);
        if ($data->{plan_type} eq 'stepped') {
            print_display_stepped ($fh, $data);
        }
        elsif ($data->{plan_type} eq 'slanted') {
            print_display_slanted ($fh, $data);
        }
        print_display_bottom  ($fh, $data);

        undef $fh;       # automatically closes the file
    }
}

###########################################################################
###########################################################################

sub display_plan
{
	my $planname = shift;

    _error ("$planname.json not available") unless (-s "$plansdir/$planname.json");
    my $json = JSON->new->pretty ();
    my $plan = slurp_json ("$plansdir/$planname.json", $json);

	if ($plan->{plan_type} eq 'stepped') {
		print "         low        high        margin        total  rate\n",
			  "------------ ------------ ------------ ------------ -----\n";
		foreach my $row (@{$plan->{calculatable}}) {
			printf  ("%12d %12.2f %12.2f %12.2f %5.1f\n",
                     ( map { $row->{$_} } qw (low high margin running_total rate) ));
		}
	}
	else {
		print Dumper ($plan->{calculatable});
	}
	print "\n\n";
}

###########################################################################

sub load_all_plans_data
{
    _say 'entering load_all_plans_data';
    opendir (DIR, $plansdir) or die "could not open $plansdir, $!";
    my @files = sort
                map { $_ =~ m/(.*?)\.json/ ; ($1) }
                grep { /\.json/ } readdir DIR;
    closedir DIR;

    my $json = JSON->new->pretty ();
    %vault = (planlist => \@files,
              data => {},
             );

    foreach my $planname (@files) {
        _say ("   now on $planname");
        $vault{data}{$planname} = slurp_json ("$plansdir/$planname.json", $json);
        $vault{data}{$planname}{due} = {};
    }
}

################################################ subroutine header begin ##
# This message should support the options given in the GetOptions call later.
# For more information on how to configure options go to the documentation for
# Getopt::Long at http://search.cpan.org/author/JHI/perl-5.8.0/lib/Getopt/Long.pm
################################################## subroutine header end ##

sub Usage
{

my $message = <<ENDOFUSAGE;
$0 [-h]

Currently supported flags
  -h -help      Display this help message
  -v -verbose	Show more information while it runs
  -d -debug     Used to see the commands without actually running them
  -r -raw       Rebuild plan details from raw yaml (only when adding plan)


Currently supported parameters
  -m -mode      What task do we what to do, pick from:
                  build         Compare all the plan pairs, build html
                  single        Quick print to STDOUT of the selected -before
  -b -before	Plan to work from
  -a -after     Plan to compare against it
  -x -maxincome	Maximum income for the speadsheet


$0 version $VERSION
ENDOFUSAGE

    return (join ("\n\n", @_, $message));
}

###########################################################################
###########################################################################

# Exectution of the Program really begins here

###########################################################################
###########################################################################

die Usage if (exists $opts{help});
 
if (exists $opts{raw}) {
    process_raw_to_usable ();
    exit (0); #may want to remove this when things are working
}

if ($opts{mode} eq 'build') {
    load_all_plans_data ();
    document_plans ();
    #process_usable_to_display ();
}
elsif ($opts{mode} eq 'single') {
    display_plan ($opts{before});
}
else {
	die Usage "Need to pick a mode to do something";
}

###########################################################################
###########################################################################
###########################################################################

__END__

