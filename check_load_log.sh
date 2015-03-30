for i in $( ls ); do
    echo $i
    cat $i  | grep Operation  | awk '{print $7; }' | sed s/,// | awk '{s+=$1} END {print s}'
done
