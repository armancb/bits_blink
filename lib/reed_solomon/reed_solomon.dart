import 'galois_field.dart';

List<int>? rsCorrectMessage(List<int> messageIn, int nsym) {
  List<int> messageOut = List<int>.of(messageIn);
  List<int> erasePos = [];
  for (int i = 0; i < messageOut.length; i++) {
    if (messageOut[i] < 0) {
      messageOut[i] = 0;
      erasePos.add(i);
    }
  }
  if (erasePos.length > nsym) return null;
  List<int> synd = _rsCalculateSyndrome(messageOut, nsym);
  if (_max(synd) == 0) return messageOut;
  List<int> fsynd = _rsForneySyndrome(synd, erasePos, messageOut.length);
  List<int>? errPolynomial = _rsGeneratorErrorPolynomial(fsynd);
  if (errPolynomial == null) return null;
  List<int>? errPos = _rsFindErrors(errPolynomial, messageOut.length);
  if (errPos == null) return null;
  messageOut = _rsCorrectErrata(messageOut, synd, erasePos..addAll(errPos));
  synd = _rsCalculateSyndrome(messageOut, nsym);
  if (_max(synd) > 0) return null;
  return messageOut;
}

/// Reed-Solomon main encoding function, using polynomial division
/// (algorithm Extended Synthetic Division).
List<int> rsEncodeMessage(List<int> messageIn, int nsym) {
  List<int> gen = _rsGeneratorPolynomial(nsym);
  List<int> messageOut = List.filled(messageIn.length + gen.length - 1, 0);
  messageOut.setAll(0, messageIn);
  for (int i = 0; i < messageIn.length; i++) {
    int coef = messageOut[i];
    if (coef != 0) {
      for (int j = 1; j < gen.length; j++) {
        messageOut[i + j] ^= gfMultiply(gen[j], coef);
      }
    }
  }
  messageOut.setAll(0, messageIn);
  return List<int>.of(messageOut);
}

int _max(List<int> list) {
  int r = list[0];
  for (int i = 1; i < list.length; i++) {
    if (list[i] > r) {
      r = list[i];
    }
  }
  return r;
}

/// Calculate the syndromes.
List<int> _rsCalculateSyndrome(List<int> msg, int nsym) {
  List<int> synd = List.filled(nsym, 0);
  for (int i = 0; i < nsym; i++) {
    synd[i] = gfPolynomialEval(msg, gfExp[i]);
  }
  return synd;
}

/// Forney algorithm, computes the values (error magnitude)
/// to correct the input message.
List<int> _rsCorrectErrata(List<int> message, List<int> synd, List<int> pos) {
  List<int> coefPos = <int>[];
  for (final value in pos) {
    coefPos.add(message.length - 1 - value);
  }
  List<int> loc = _rsFindErrataLocator(coefPos);
  List<int> reversed = List<int>.of(synd.sublist(0, pos.length).reversed);
  List<int> eval = _rsFindErrorEvaluator(reversed, loc, pos.length - 1);
  List<int> locPrime = <int>[];
  bool skipNext = false;
  locPrime.addAll(
    loc.skip(loc.length & 1).where((int value) {
      skipNext = !skipNext;
      return skipNext;
    }),
  );
  for (final value in pos) {
    int x = gfExp[value + gfLogSize - message.length];
    int y = gfPolynomialEval(eval, x);
    int z = gfPolynomialEval(locPrime, gfMultiply(x, x));
    int magnitude = gfDivide(y, gfMultiply(x, z));
    message[value] ^= magnitude;
  }
  return message;
}

/// Compute the erasures/errors/errata locator polynomial from the
/// erasures/errors/errata positions.
List<int> _rsFindErrataLocator(List<int> ePos) {
  List<int> eLoc = [1];
  for (int x in ePos) {
    eLoc = gfPolynomialMultiply(eLoc, gfPolynomialAdd([1], [gfExp[x], 0]));
  }
  return eLoc;
}

/// Compute the error evaluator polynomial Omega from the syndrome
/// and the error/erasures/errata locator Sigma.
List<int> _rsFindErrorEvaluator(List<int> synd, List<int> errLoc, int nsym) {
  List<int> remainder = gfPolynomialDivide(gfPolynomialMultiply(synd, errLoc), [
    1,
    ...List.filled(nsym + 1, 0),
  ]);
  return remainder;
}

/// Find the roots of error polynomial by brute-force trial (Chien's search).
List<int>? _rsFindErrors(List<int> errLoc, int nmess) {
  int errs = errLoc.length - 1;
  List<int> errPos = <int>[];
  for (int i = 0; i < nmess; i++) {
    if (gfPolynomialEval(errLoc, gfExp[(gfLogSize - 1) - i]) == 0) {
      errPos.add(nmess - 1 - i);
    }
  }
  if (errPos.length != errs) {
    return null;
  }
  return errPos;
}

/// Calculating the Forney syndromes.
List<int> _rsForneySyndrome(List<int> synd, List<int> pos, int nmess) {
  List<int> fsynd = List<int>.of(synd);
  for (final value in pos) {
    int x = gfExp[nmess - 1 - value];
    for (int j = 0; j < fsynd.length - 1; j++) {
      fsynd[j] = gfMultiply(fsynd[j], x) ^ fsynd[j + 1];
    }
    fsynd.removeLast();
  }
  return fsynd;
}

/// Find error locator polynomial with Berlekamp-Massey algorithm.
List<int>? _rsGeneratorErrorPolynomial(List<int> synd) {
  List<int> errLoc = [1];
  List<int> oldLoc = [1];

  for (int i = 0; i < synd.length; i++) {
    oldLoc.add(0);
    int delta = synd[i];
    for (int j = 1; j < errLoc.length; j++) {
      delta ^= gfMultiply(errLoc[errLoc.length - 1 - j], synd[i - j]);
    }
    if (delta != 0) {
      if (oldLoc.length > errLoc.length) {
        List<int> newLoc = gfPolynomialScale(oldLoc, delta);
        oldLoc = gfPolynomialScale(errLoc, gfInverse(delta));
        errLoc = newLoc;
      }
      errLoc = gfPolynomialAdd(errLoc, gfPolynomialScale(oldLoc, delta));
    }
  }
  errLoc.removeWhere((int value) => value == 0);
  int errs = errLoc.length - 1;
  if (errs * 2 > synd.length) {
    return null;
  }
  return errLoc;
}

/// Computes the generator polynomial for a given number of error
/// correction symbols.
List<int> _rsGeneratorPolynomial(int nsym) {
  List<int> g = [1];
  for (int i = 0; i < nsym; i++) {
    g = gfPolynomialMultiply(g, [1, gfExp[i]]);
  }
  return g;
}
