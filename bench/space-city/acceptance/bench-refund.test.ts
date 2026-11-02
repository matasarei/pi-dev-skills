// Hidden acceptance test for step 3 of the space-city benchmark. Never shown to the model.
import { describe, it, expect } from 'vitest';
import { CityManager } from '../core/cityManager';
import { ZoneType } from '../core/zone';

describe('bench step 3: refunds', () => {
    it('refunds half the cost of a cleared zone', () => {
        const m = new CityManager(20, 20, false);
        m.placeZone(14, 14, ZoneType.Residential);
        expect(m.clearZone(15, 15)).toBe(true);
        expect(m.funds).toBe(1950);
    });
    it('rounds an odd half down', () => {
        const m = new CityManager(20, 20, false);
        m.placeZone(1, 18, ZoneType.PowerLine);
        m.clearZone(1, 18);
        expect(m.funds).toBe(1997);
    });
    it('refunds a road and a power line on one cell together', () => {
        const m = new CityManager(20, 20, false);
        m.placeZone(1, 18, ZoneType.Transit);
        m.placeZone(1, 18, ZoneType.PowerLine);
        expect(m.funds).toBe(1985);
        m.clearZone(1, 18);
        expect(m.funds).toBe(1992);
    });
    it('refunds nothing for the free LandingBase', () => {
        const m = new CityManager(20, 20, false);
        const base = m.zones.find(z => z.type === ZoneType.LandingBase)!;
        expect(m.clearZone(base.centerX, base.centerY)).toBe(true);
        expect(m.funds).toBe(2000);
    });
    it('changes nothing when there is nothing to clear', () => {
        const m = new CityManager(20, 20, false);
        expect(m.clearZone(18, 1)).toBe(false);
        expect(m.clearZone(-1, -1)).toBe(false);
        expect(m.funds).toBe(2000);
    });
});
