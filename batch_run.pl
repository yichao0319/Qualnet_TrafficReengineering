#!/user/local/bin/perl -w
##
## Yi-Chao
##
########################################################



## data rates: bps
my @rates_a = (6000000);    
my @rates_b = (5500000); #(2000000, 5500000, 11000000);

## CBR packet size, intervals, start time
my @flow0_sizes = (2000); #(1000, 2000); #
my @flow1_sizes = (2000); #(1000, 2000);
my @flow0_intvs = (0.001); #(0.001, 0.01); # 
my @flow1_intvs = (0.001); #(0.001, 0.01);
my @flow0_start_times = (0);
my @flow1_start_times = (0);

## use global information
my @global_informations = (0, 1);


#####
## perl run.pl <rate of 11a> <rate of 11b> <flow 0 pkt size> <flow 1 pkt size> <flow 0 interval> <flow 1 interval> <flow 0 start time> <flow 1 start time>


foreach my $global_information (@global_informations) {

    foreach my $rate_a (@rates_a) {
        foreach my $rate_b (@rates_b) {

            foreach my $flow0_start_time (@flow0_start_times) {
                foreach my $flow1_start_time (@flow1_start_times) {

                    foreach my $flow0_size (@flow0_sizes) {
                        foreach my $flow1_size (@flow1_sizes) { 

                            foreach my $flow0_intv (@flow0_intvs) {
                                foreach my $flow1_intv (@flow1_intvs) {

                                    my $cmd = "perl run.pl $rate_a $rate_b $flow0_size $flow1_size $flow0_intv $flow1_intv $flow0_start_time $flow1_start_time $global_information";
                                    print `$cmd`;

                                }
                            } ## end of flow 0 CBR packet interval

                        }
                    } ## end of flow 0 CBR packet size


                }
            } ## end of flow 0 start time

        }
    } ## end of 11a rate

} ## end of using global information
