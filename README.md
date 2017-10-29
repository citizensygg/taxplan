# taxplan
Tool to compare various income tax plans.

When a new plan is added to data/rawplans/ we need to rebuild the data/details

    perl process-plans.pl -raw

After running -raw or changing the script we need to rebuild the pages of the website

    perl process-plans.pl -mode build

To see the resulting website use

    https://citizensygg.github.io/taxplan/index.html


