late List<int> gfExp;
late List<int> gfLog;
late int gfExpSize;
late int gfLogSize;

int gfDivide(int x, int y) {
  if (y == 0) {
    throw ArgumentError('Divide by 0');
  }
  if (x == 0) {
    return 0;
  }
  return gfExp[gfLog[x] + (gfLogSize - 1) - gfLog[y]];
}

int gfInverse(int y) {
  return gfDivide(1, y);
}

int gfMultiply(int x, int y) {
  if (x == 0 || y == 0) return 0;
  return gfExp[gfLog[x] + gfLog[y]];
}

/// Addition of two polynomials (using exclusive-or, as usual).
List<int> gfPolynomialAdd(List<int> p, List<int> q) {
  List<int> r = List.filled(p.length > q.length ? p.length : q.length, 0);
  for (int i = 0; i < p.length; i++) {
    r[i + r.length - p.length] = p[i];
  }
  for (int i = 0; i < q.length; i++) {
    r[i + r.length - q.length] ^= q[i];
  }
  return List<int>.of(r);
}

/// Fast polynomial division by using Extended Synthetic Division,
/// optimized for GF(2^p) computations.
///
/// Does not work with standard polynomials outside of this galois field;
/// see the Wikipedia article for the generic algorithm.
List<int> gfPolynomialDivide(List<int> dividend, List<int> divisor) {
  List<int> msgOut = List<int>.of(dividend);
  for (int i = 0; i < dividend.length - (divisor.length - 1); i++) {
    int coef = msgOut[i];
    if (coef != 0) {
      for (int j = 1; j < divisor.length; j++) {
        msgOut[i + j] ^= gfMultiply(divisor[j], coef);
      }
    }
  }
  int separator = divisor.length - 1;
  return msgOut.sublist(msgOut.length - separator);
}

/// Evaluate a polynomial at a particular value of x, producing a scalar result.
int gfPolynomialEval(List<int> p, int x) {
  int y = p[0];
  for (int i = 1; i < p.length; i++) {
    y = gfMultiply(y, x) ^ p[i];
  }
  return y;
}

/// Multiplies two polynomials.
List<int> gfPolynomialMultiply(List<int> p, List<int> q) {
  List<int> r = List.filled(p.length + q.length - 1, 0);
  for (int j = 0; j < q.length; j++) {
    for (int i = 0; i < p.length; i++) {
      r[i + j] ^= gfMultiply(p[i], q[j]);
    }
  }
  return List<int>.of(r);
}

/// Multiplies a polynomial by a scalar.
List<int> gfPolynomialScale(List<int> p, int x) {
  List<int> r = List.filled(p.length, 0);
  for (int i = 0; i < p.length; i++) {
    r[i] = gfMultiply(p[i], x);
  }
  return List<int>.of(r);
}

// Possible primitive polynomial values:
//   0x0, 0x3, 0x7, 0xB, 0x13, 0x25, 0x43, 0x83,
//   0x11D, 0x211, 0x409, 0x805, 0x1053, 0x201B, 0x402B, 0x8003, 0x1100B
void initTables() => _initTables(0x11D);

/// Precompute the logarithm and anti-log tables for faster computation later,
/// using the provided primitive polynomial.
void _initTables(int prim) {
  List<int> prims = [
    0x0,
    0x3,
    0x7,
    0xB,
    0x13,
    0x25,
    0x43,
    0x83,
    0x11D,
    0x211,
    0x409,
    0x805,
    0x1053,
    0x201B,
    0x402B,
    0x8003,
    0x1100B,
  ];
  int pos = prims.indexOf(prim);
  gfLogSize = 1 << pos;
  gfExpSize = gfLogSize * 2;
  gfExp = List.filled(gfExpSize, 1);
  gfLog = List.filled(gfLogSize, 0);
  int logMinusOne = gfLogSize - 1;
  int x = 1;
  for (int i = 1; i < logMinusOne; i++) {
    x <<= 1;
    if (x & gfLogSize == gfLogSize) {
      x ^= prim;
    }
    gfExp[i] = x;
    gfLog[x] = i;
  }
  for (int i = logMinusOne; i < gfExpSize; i++) {
    gfExp[i] = gfExp[i - logMinusOne];
  }
}
