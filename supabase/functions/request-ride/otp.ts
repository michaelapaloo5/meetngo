/**
 * The four digits the driver has to be given at the pickup.
 *
 * On the trip row, and nowhere else: with no writer the column is NULL, and
 * both checkers — the driver's client-side read in
 * `SupabaseDriverRepository.verifyPickupOtp` and the `verify-pickup` function —
 * compare against `''` and reject every input, so the driver could never start
 * the trip. `request-ride` is the only thing that mints one.
 *
 * `crypto.getRandomValues` rather than `Math.random`, because this is the one
 * value in the build where a weak generator is a real answer rather than a
 * non-sequitur. The rejection sampling is what keeps it uniform: `1000 + (n %
 * 9000)` on its own would make `1000` twice as likely as every other code,
 * because the first 1000 of the 2^32 range map onto it as well.
 */
export function pickupOtp(): string {
  const buf = new Uint32Array(1);
  const limit = Math.floor(0x100000000 / 9000) * 9000;
  let n: number;
  do {
    crypto.getRandomValues(buf);
    n = buf[0];
  } while (n >= limit);
  return String(1000 + (n % 9000));
}
