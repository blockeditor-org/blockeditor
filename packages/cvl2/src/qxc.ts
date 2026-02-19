const src = `

slash version

/rem, rem cb, rem, rem cb/ def
def /true, false, true/ true
def /true, false, false/ false
def /lhs, rhs, cb lhs rhs/ pair
def /pair lhs, rhs, lhs/ lhs
def /pair lhs, rhs, rhs/ rhs
def /t, some, none, some t/ some
def /some, none, none/ none
def /none/ empty
def /arr, item, some /pair item arr// push
def /arr, item, some = pair item arr/ push

def /
    pair true false
/ long

bracket version

[.rem rem .cb .rem rem cb] def
[.true .false .true] true


`;