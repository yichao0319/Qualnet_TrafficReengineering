#!/user/local/bin/perl -w
########################################################

use strict;

use POSIX;
use Time::HiRes qw(usleep ualarm gettimeofday tv_interval);



#####
## constant
my $DEBUG0 = 0;
my $DEBUG1 = 1;
my $DEBUG2 = 1;

my $MAX_ROUND = 20;

#####
## global variables
my $rate_a = 6000000; ## 6Mbps
my $rate_b = 5500000; ## 2Mbps

my $flow0_start_time = 0;   ## flow 0 starts to transmit at XX second
my $flow0_size = 1000;      ## flow 0 generates a 1000byte pkt per 0.001 seconds
my $flow0_intv = 0.001;     ## 
my $flow1_start_time = 0;   ## flow 1 starts to transmit at XX second
my $flow1_size = 2000;      ## flow 1 generates a 1000byte pkt per 0.001 seconds
my $flow1_intv = 0.001;     ## 


my $qualnet_exec = "../qualnet";
my $app_filename = "SelectLink.app";
my $config_mother_filename = "SelectLink.mother.config";
my $config_filename = "SelectLink.config";
my $stat_filename = "SelectLink.stat";

my %demands = ();    ## $demands{flow}{xx}{ size | interval }
my %load_stage = (); ## $load_stage{flow}{xx}{ stage | lower | upper }{xx}

my $cnt_round = 0;
my %throughput = ();  ## %throughput{round}{xx}{flow}{ 0 | 1 }{ throughput_total | throughput_a | throughput_b | load_a | load_b }{xx}



#####
## main starts

#####
## initialization
assign_demands();
init_load_stage();


foreach my $round_i (0 .. $MAX_ROUND-1) {
    print "> round $round_i:\n" if($DEBUG1);


    #####
    ## get load for each interface depends on previous throughput
    calculate_load_per_interface($round_i);
    # calculate_load_globally($round_i);


    #####
    ## interface a
    clean_file($app_filename);
    create_config('a');
    create_app($round_i, 'a');

    clean_file($stat_filename);
    my $cmd = "$qualnet_exec $config_filename 2> /dev/null";
    `$cmd`;
    get_throughput($round_i, 'a');

    # exit if($round_i == 6);


    #####
    ## interface b
    clean_file($app_filename);
    create_config('b');
    create_app($round_i, 'b');

    clean_file($stat_filename);
    my $cmd = "$qualnet_exec $config_filename 2> /dev/null";
    `$cmd`;
    get_throughput($round_i, 'b');
    # exit;


}   # end of all rounds



print "\n\n\n";
print_throughput();
1;






#####
## function

#####
## assign CBR traffic for each flow
sub assign_demands {
    $demands{flow}{0}{size} = $flow0_size; # bytes
    $demands{flow}{0}{interval} = $flow0_intv; # seconds

    $demands{flow}{1}{size} = $flow1_size; # bytes
    $demands{flow}{1}{interval} = $flow1_intv; # seconds
}


#####
## initialization for load balanceing algorithm
sub init_load_stage {

    foreach my $flow_i (sort {$a <=> $b} keys %{$demands{flow}}) {
        $load_stage{flow}{$flow_i}{stage} = 0;
    }

}


#####
## load balancing algorithm
##   stage 0: exponentially increase 11b load
##   stage 1: binary search
sub calculate_load_per_interface {
    my ($round_i) = @_;


    foreach my $flow_i (sort {$a <=> $b} keys %{$demands{flow}}) {
        my ($new_load_a, $new_load_b);

        ## first round: 0.99, 0.01
        if($round_i == 0) {
            ($new_load_a, $new_load_b) = (0.96, 0.04);
        }
        ## second round: 0.98, 0.02
        elsif($round_i == 1) {
            ($new_load_a, $new_load_b) = (0.92, 0.08);
        }
        ## thereafter
        else {
            my $pre_throughput = $throughput{round}{$round_i-1}{flow}{$flow_i}{throughput_total};
            my $pre_load_a     = $throughput{round}{$round_i-1}{flow}{$flow_i}{load_a};
            my $pre_load_b     = $throughput{round}{$round_i-1}{flow}{$flow_i}{load_b};
            my $pre2_throughput = $throughput{round}{$round_i-2}{flow}{$flow_i}{throughput_total};
            my $pre2_load_a     = $throughput{round}{$round_i-2}{flow}{$flow_i}{load_a};
            my $pre2_load_b     = $throughput{round}{$round_i-2}{flow}{$flow_i}{load_b};

            #####
            ## stage 0: exponentially increase 11b load
            if($load_stage{flow}{$flow_i}{stage} == 0) {
                ## if throughput improve, move more to 11b
                if($pre_throughput > $pre2_throughput) {
                    $new_load_b = $pre_load_b * 2;
                    $new_load_a = $pre_load_a - $pre_load_b;
                }
                ## if not improve, move to stage 1 and take the average of pre and pre2
                else {
                    $new_load_b = ($pre_load_b + $pre2_load_b) / 2;
                    $new_load_a = $pre_load_a + $pre_load_b - $new_load_b;

                    ## set to stage 1
                    $load_stage{flow}{$flow_i}{stage} = 1;
                    $load_stage{flow}{$flow_i}{lower} = $pre2_load_b;
                    $load_stage{flow}{$flow_i}{upper} = $pre_load_b;
                }
            }
            ## stage 1: binary search
            elsif($load_stage{flow}{$flow_i}{stage} == 1) {
                ## if throughput improve, move more to 11b
                if($pre_throughput > $pre2_throughput) {
                    $new_load_b = ($pre_load_b + $load_stage{flow}{$flow_i}{upper}) / 2;
                    $new_load_a = $pre_load_a + $pre_load_b - $new_load_b;

                    $load_stage{flow}{$flow_i}{lower} = $pre_load_b;
                }
                ## if not improve
                else {
                    $new_load_b = ($pre_load_b + $load_stage{flow}{$flow_i}{lower}) / 2;
                    $new_load_a = $pre_load_a + $pre_load_b - $new_load_b;

                    $load_stage{flow}{$flow_i}{upper} = $pre_load_b;
                }
            }
            else {
                die "wrong stage\n";
            }
            
        }


        ## special case
        if($new_load_a >= 1) {
            $new_load_a = 1;
            $new_load_b = 0;
        }
        if($new_load_b >= 1) {
            $new_load_b = 1;
            $new_load_a = 0;
        }


        $throughput{round}{$round_i}{flow}{$flow_i}{load_a} = $new_load_a;
        $throughput{round}{$round_i}{flow}{$flow_i}{load_b} = $new_load_b;
    }    
}



#####
## load balancing algorithm -- global view
##   stage 0: exponentially increase 11b load
##   stage 1: binary search
sub calculate_load_globally {
    my ($round_i) = @_;


    foreach my $flow_i (sort {$a <=> $b} keys %{$demands{flow}}) {
        my ($new_load_a, $new_load_b);

        ## first round: 0.99, 0.01
        if($round_i == 0) {
            ($new_load_a, $new_load_b) = (0.96, 0.04);
        }
        ## second round: 0.98, 0.02
        elsif($round_i == 1) {
            ($new_load_a, $new_load_b) = (0.92, 0.08);
        }
        ## thereafter
        else {
            my $pre_throughput = 0;
            my $pre2_throughput = 0;
            foreach my $flow_j (sort {$a <=> $b} keys %{$demands{flow}}) {
                $pre_throughput += $throughput{round}{$round_i-1}{flow}{$flow_j}{throughput_total};
                $pre2_throughput += $throughput{round}{$round_i-2}{flow}{$flow_j}{throughput_total};
            }
            my $pre_load_a     = $throughput{round}{$round_i-1}{flow}{$flow_i}{load_a};
            my $pre_load_b     = $throughput{round}{$round_i-1}{flow}{$flow_i}{load_b};
            my $pre2_load_a     = $throughput{round}{$round_i-2}{flow}{$flow_i}{load_a};
            my $pre2_load_b     = $throughput{round}{$round_i-2}{flow}{$flow_i}{load_b};

            #####
            ## stage 0: exponentially increase 11b load
            if($load_stage{flow}{$flow_i}{stage} == 0) {
                ## if throughput improve, move more to 11b
                if($pre_throughput > $pre2_throughput) {
                    $new_load_b = $pre_load_b * 2;
                    $new_load_a = $pre_load_a - $pre_load_b;
                }
                ## if not improve, move to stage 1 and take the average of pre and pre2
                else {
                    $new_load_b = ($pre_load_b + $pre2_load_b) / 2;
                    $new_load_a = $pre_load_a + $pre_load_b - $new_load_b;

                    ## set to stage 1
                    $load_stage{flow}{$flow_i}{stage} = 1;
                    $load_stage{flow}{$flow_i}{lower} = $pre2_load_b;
                    $load_stage{flow}{$flow_i}{upper} = $pre_load_b;
                }
            }
            ## stage 1: binary search
            elsif($load_stage{flow}{$flow_i}{stage} == 1) {
                ## if throughput improve, move more to 11b
                if($pre_throughput > $pre2_throughput) {
                    $new_load_b = ($pre_load_b + $load_stage{flow}{$flow_i}{upper}) / 2;
                    $new_load_a = $pre_load_a + $pre_load_b - $new_load_b;

                    $load_stage{flow}{$flow_i}{lower} = $pre_load_b;
                }
                ## if not improve
                else {
                    $new_load_b = ($pre_load_b + $load_stage{flow}{$flow_i}{lower}) / 2;
                    $new_load_a = $pre_load_a + $pre_load_b - $new_load_b;

                    $load_stage{flow}{$flow_i}{upper} = $pre_load_b;
                }
            }
            else {
                die "wrong stage\n";
            }
            
        }


        ## special case
        if($new_load_a >= 1) {
            $new_load_a = 1;
            $new_load_b = 0;
        }
        if($new_load_b >= 1) {
            $new_load_b = 1;
            $new_load_a = 0;
        }


        $throughput{round}{$round_i}{flow}{$flow_i}{load_a} = $new_load_a;
        $throughput{round}{$round_i}{flow}{$flow_i}{load_b} = $new_load_b;
    }    
}


#####
## modify config file according to 
##   1) 11a or 11b link
##   2) data rate
##   3) frequency -- not done yet
sub create_config {
    my ($interface) = @_;

    if($interface eq 'a') {
        system("sed 's/PHY-MODEL PHY802.11b/PHY-MODEL PHY802.11a/g;s/PHY-RX-MODEL PHY802.11b/PHY-RX-MODEL PHY802.11a/g;s/PHY802.11-DATA-RATE 2000000/PHY802.11-DATA-RATE $rate_a/g;' $config_mother_filename > $config_filename");
    }
    elsif($interface eq 'b') {
        system("sed 's/PHY802.11-DATA-RATE 2000000/PHY802.11-DATA-RATE $rate_b/g;' $config_mother_filename > $config_filename");
    }
}



#####
## generate app file which specifies the CBR traffic for each flow
sub create_app {
    my ($round_i, $interface) = @_;


    foreach my $flow_i (sort {$a <=> $b} keys %{$demands{flow}}) {
        print " flows $flow_i\n" if($DEBUG0);


        #####
        ## get demands of this flow
        my $demand_size = $demands{flow}{$flow_i}{size};
        my $demand_interval = $demands{flow}{$flow_i}{interval};


        #####
        ## get load for this interface (11a or 11b) calculated by load balancing algorithm
        my $ratio_interface;
        if($interface eq 'a') {
            $ratio_interface = $throughput{round}{$round_i}{flow}{$flow_i}{load_a};
        }
        elsif($interface eq 'b') {
            $ratio_interface = $throughput{round}{$round_i}{flow}{$flow_i}{load_b};
        }
        else {
            die "wrong interface\n";
        }
        ## CBR packet size must be an integer (by Qualnet)
        my $demand_size_interface = ceil($demand_size * $ratio_interface);  
        my $demand_invl_interface = $demand_interval;
        print $demand_size_interface."\n";


        #####
        ## generate app file
        ##   CBR
        ##   e.g. CBR 1 2 0 1000 0.0001S 0S 0S
        if($flow_i == 0) {
            if($demand_size_interface >= 40) {
                system('echo "CBR 1 2 0 '.$demand_size_interface.' '.$demand_invl_interface.'S '.$flow0_start_time.'S 0S" >> '.$app_filename);
            }
            else {
                system("touch $app_filename");
            }
        }
        elsif($flow_i == 1) {
            if($demand_size_interface >= 40) {
                system('echo "CBR 4 3 0 '.$demand_size_interface.' '.$demand_invl_interface.'S '.$flow0_start_time.'S 0S" >> '.$app_filename);
            }
        }
        else {
            die "wrong number of flows\n";
        }
    }
}


#####
## remove old configure or output file
##   backup if in debug mode
sub clean_file {
    my ($filename) = @_;

    system('cat '.$filename.' >> bak.'.$filename) if($DEBUG2);
    system('echo "\n" >> bak.'.$filename) if($DEBUG2);
    system('rm '.$filename);
}


#####
## parse Qualnet output file to get CBR throughput
sub get_throughput {
    my ($round_i, $interface) = @_;


    foreach my $flow_i (sort {$a <=> $b} keys %{$demands{flow}}) {
        print " flows $flow_i\n" if($DEBUG1);


        my $file;
        if($flow_i == 0) {
            $file = "cat $stat_filename | grep CBR | grep Throughput | grep 2, |";
        }
        elsif($flow_i == 1) {
            $file = "cat $stat_filename | grep CBR | grep Throughput | grep 3, |";
        }

        my $new_throughput = 0;
        open FH, $file or die $!;
        while(<FH>) {
            print $_ if($DEBUG0);

            if($_ =~ /=\s+(\d+\.\d*)/) {
                $new_throughput = $1;
            }

            print $new_throughput."\n" if($DEBUG0);
            last;
        }
        close FH;


        if($interface eq 'a') {
            $throughput{round}{$round_i}{flow}{$flow_i}{throughput_a} = $new_throughput;
            $throughput{round}{$round_i}{flow}{$flow_i}{throughput_total} = $new_throughput;

            print "   a=$new_throughput\n" if($DEBUG1);
        }
        elsif($interface eq 'b') {
            $throughput{round}{$round_i}{flow}{$flow_i}{throughput_b} = $new_throughput;
            $throughput{round}{$round_i}{flow}{$flow_i}{throughput_total} += $new_throughput;

            print "   b=$new_throughput, sum=".$throughput{round}{$round_i}{flow}{$flow_i}{throughput_total}."\n" if($DEBUG1);
        }
    }
}



#####
## print out %throughput
##   %throughput has entire information of this simulation
##   - %throughput format: 
##     %throughput{round}{xx}{flow}{ 0 | 1 }{ throughput_total | throughput_a | throughput_b | load_a | load_b }{xx}
##   - print format: 
##     round, [flow1: load_a, load_b, throughput_sum, throughput1, throughput2], [flow2: load_a, load_b, throughput_sum, throughput1, throughput2], ...
sub print_throughput {
    
    print "round, [flow1: load_a, load_b, throughput_sum, throughput1, throughput2], [flow2: load_a, load_b, throughput_sum, throughput1, throughput2], ...\n";
    foreach my $round_i (sort {$a <=> $b} keys %{$throughput{round}}) {
        print "t$round_i, ";

        foreach my $flow_i (sort {$a <=> $b} keys %{$throughput{round}{$round_i}{flow}}) {
            print "f$flow_i, ";

            print $throughput{round}{$round_i}{flow}{$flow_i}{load_a}.", ".$throughput{round}{$round_i}{flow}{$flow_i}{load_b}.", ".$throughput{round}{$round_i}{flow}{$flow_i}{throughput_total}.", ".$throughput{round}{$round_i}{flow}{$flow_i}{throughput_a}.", ".$throughput{round}{$round_i}{flow}{$flow_i}{throughput_b}.", ";
        }

        print "\n";
    }
}
