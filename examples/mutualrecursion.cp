module main;

extern printf(str, bool): unit;

fn even(n)
    if n == 0
        true
    else
        odd(n - 1);

fn odd(n)
    if n == 0
        false
    else
        even(n - 1);

fn main() {
    printf("%d\n", even(20));
};