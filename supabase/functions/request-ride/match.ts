export interface Candidate {
  id: string;
  pickupDistanceKm: number;
}

export const MAX_OFFERS = 5;

export function pickDrivers(candidates: Candidate[], max: number): string[] {
  return [...candidates]
    .sort((a, b) => a.pickupDistanceKm - b.pickupDistanceKm)
    .slice(0, max)
    .map((c) => c.id);
}
