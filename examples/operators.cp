module main;

extern printf(str, i32): unit;

op infixr 10 ** (base: i32, exp: i32) {
    mut res := 1;
    mut exp2 := exp;
    while exp2 > 0 {
        res = res * base;
        exp2 = exp2 - 1;
    };
    res
};

fn main() {
    printf("%d\n", 2**12);
};