import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { pickDrivers } from '../request-ride/match.ts';

Deno.test('takes the five nearest drivers in order', () => {
  const drivers = [
    { id: 'a', pickupDistanceKm: 0.4 },
    { id: 'b', pickupDistanceKm: 0.1 },
    { id: 'c', pickupDistanceKm: 3.0 },
    { id: 'd', pickupDistanceKm: 1.2 },
    { id: 'e', pickupDistanceKm: 0.9 },
    { id: 'f', pickupDistanceKm: 0.2 },
  ];
  assertEquals(pickDrivers(drivers, 5), ['b', 'f', 'a', 'e', 'd']);
});

Deno.test('fewer candidates than the cap is fine', () => {
  assertEquals(pickDrivers([{ id: 'only', pickupDistanceKm: 1 }], 5), ['only']);
});

Deno.test('empty candidate list yields no offers', () => {
  assertEquals(pickDrivers([], 5), []);
});

Deno.test('does not mutate the input array', () => {
  const drivers = [
    { id: 'far', pickupDistanceKm: 9 },
    { id: 'near', pickupDistanceKm: 1 },
  ];
  pickDrivers(drivers, 5);
  assertEquals(drivers[0].id, 'far');
});
