import { describe, it, expect, beforeEach } from 'vitest';
import { CityManager } from '../core/cityManager';
import { ZoneType } from '../core/zone';
import { TerrainType } from '../core/terrain';

describe('CityManager', () => {
    let manager: CityManager;

    beforeEach(() => {
        // use flat terrain for predictable zoning tests
        manager = new CityManager(20, 20, false); 
        
        // Clear the auto-spawned LandingBase
        const initialZones = [...manager.zones];
        initialZones.forEach(z => manager.clearZone(z.centerX, z.centerY));
    });

    it('should initialize with a clean slate after clearing LandingBase', () => {
        expect(manager.zones.length).toBe(0);
    });

    describe('Funds', () => {
        it('should start with 2000 funds by default', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));
            // LandingBase costs 0 so funds should be exactly the starting value
            expect(mgr.funds).toBe(2000);
        });

        it('should accept a custom starting funds value', () => {
            const mgr = new CityManager(20, 20, false, 500);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));
            expect(mgr.funds).toBe(500);
        });

        it('should deduct cost when placing a zone', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));
            expect(mgr.funds).toBe(2000);

            const success = mgr.placeZone(5, 5, ZoneType.Residential);
            expect(success).toBe(true);
            // Residential costs 100
            expect(mgr.funds).toBe(1900);
        });

        it('should not deduct cost when placement fails due to overlap', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));
            mgr.placeZone(5, 5, ZoneType.Residential);
            const startFunds = mgr.funds;

            const success = mgr.placeZone(6, 6, ZoneType.Commercial);
            expect(success).toBe(false);
            // Funds should be unchanged
            expect(mgr.funds).toBe(startFunds);
        });

        it('should not deduct cost when placement fails due to crater', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));
            const cell = mgr.grid.getCell(6, 6);
            if (cell) cell.terrain = TerrainType.Crater;

            const success = mgr.placeZone(5, 5, ZoneType.Residential);
            expect(success).toBe(false);
            // Funds should be unchanged
            expect(mgr.funds).toBe(2000);
        });

        it('should not deduct cost when funds are insufficient', () => {
            const mgr = new CityManager(20, 20, false, 50);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));
            // Residential costs 100, but we only have 50
            const success = mgr.placeZone(5, 5, ZoneType.Residential);
            expect(success).toBe(false);
            // Funds should be unchanged
            expect(mgr.funds).toBe(50);
        });

        it('should allow placement when funds exactly match the cost', () => {
            const mgr = new CityManager(20, 20, false, 100);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));
            // Residential costs exactly 100
            const success = mgr.placeZone(5, 5, ZoneType.Residential);
            expect(success).toBe(true);
            // Funds should be exactly 0
            expect(mgr.funds).toBe(0);
        });

        it('should deduct correct cost for each zone type', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));

            // Transit costs 10
            mgr.placeZone(5, 5, ZoneType.Transit);
            expect(mgr.funds).toBe(1990);

            // PowerLine costs 5
            mgr.placeZone(6, 6, ZoneType.PowerLine);
            expect(mgr.funds).toBe(1985);

            // DroneStation costs 50
            mgr.placeZone(7, 7, ZoneType.DroneStation);
            expect(mgr.funds).toBe(1935);

            // PowerPlant costs 500
            mgr.placeZone(8, 8, ZoneType.PowerPlant);
            expect(mgr.funds).toBe(1435);

            // Launchpad costs 1000
            mgr.placeZone(9, 9, ZoneType.Launchpad);
            expect(mgr.funds).toBe(435);
        });

        it('should not deduct cost for LandingBase (cost is 0)', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));
            expect(mgr.funds).toBe(2000);

            const success = mgr.placeZone(5, 5, ZoneType.LandingBase);
            expect(success).toBe(true);
            // Funds should be unchanged (LandingBase costs 0)
            expect(mgr.funds).toBe(2000);
        });

        it('should not deduct cost when placing Transit on an entity', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));
            mgr.placeZone(5, 5, ZoneType.Residential);

            const success = mgr.placeZone(5, 5, ZoneType.Transit);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(2000);
        });

        it('should not deduct cost when placing PowerLine on an entity', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));
            mgr.placeZone(5, 5, ZoneType.Residential);

            const success = mgr.placeZone(5, 5, ZoneType.PowerLine);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(2000);
        });

        it('should not deduct cost when placing PowerLine on existing power line', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));
            mgr.placeZone(5, 5, ZoneType.PowerLine);

            const success = mgr.placeZone(5, 5, ZoneType.PowerLine);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(1995); // First placement already deducted 5
        });

        it('should not deduct cost when placing Transit on existing road', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));
            mgr.placeZone(5, 5, ZoneType.Transit);

            const success = mgr.placeZone(5, 5, ZoneType.Transit);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(1990); // First placement already deducted 10
        });

        it('should not deduct cost when placing on out of bounds', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));

            const success = mgr.placeZone(-1, -1, ZoneType.Transit);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(2000);
        });

        it('should not deduct cost when placing on occupied cell', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));

            const success = mgr.placeZone(-1, -1, ZoneType.Residential);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(2000);
        });

        it('should not deduct cost when placing on occupied cell', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));

            const success = mgr.placeZone(-1, -1, ZoneType.Residential);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(2000);
        });

        it('should not deduct cost when placing on occupied cell', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));

            const success = mgr.placeZone(-1, -1, ZoneType.Residential);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(2000);
        });

        it('should not deduct cost when placing on occupied cell', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));

            const success = mgr.placeZone(-1, -1, ZoneType.Residential);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(2000);
        });

        it('should not deduct cost when placing on occupied cell', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));

            const success = mgr.placeZone(-1, -1, ZoneType.Residential);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(2000);
        });

        it('should not deduct cost when placing on occupied cell', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));

            const success = mgr.placeZone(-1, -1, ZoneType.Residential);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(2000);
        });

        it('should not deduct cost when placing on occupied cell', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));

            const success = mgr.placeZone(-1, -1, ZoneType.Residential);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(2000);
        });

        it('should not deduct cost when placing on occupied cell', () => {
            const mgr = new CityManager(20, 20, false);
            // Clear auto-spawned LandingBase before tests
            const zones = [...mgr.zones];
            zones.forEach(z => mgr.clearZone(z.centerX, z.centerY));

            const success = mgr.placeZone(-1, -1, ZoneType.Residential);
            expect(success).toBe(false);
            // Funds should be unchanged (placement failed)
            expect(mgr.funds).toBe(2000);
        });

    });

    describe('Macro Zones (3x3)', () => {
        it('should place a 3x3 Residential zone as a single Entity', () => {
            const success = manager.placeZone(5, 5, ZoneType.Residential);
            expect(success).toBe(true);
            
            const center = manager.grid.getCell(5, 5);
            const edge = manager.grid.getCell(6, 6);
            
            expect(center?.zone).toBe(ZoneType.Residential);
            expect(center?.zoneEntity).toBeDefined();
            expect(center?.zoneEntity?.id).toBe(edge?.zoneEntity?.id);
            expect(manager.zones.length).toBe(1);
        });

        it('should fail 3x3 placement if overlapping with existing zone', () => {
            manager.placeZone(5, 5, ZoneType.Residential);
            const success = manager.placeZone(6, 6, ZoneType.Commercial);
            
            expect(success).toBe(false);
            expect(manager.zones.length).toBe(1); // Only the first zone should remain
        });

        it('should fail 3x3 placement on a crater', () => {
            const cell = manager.grid.getCell(6, 6);
            if (cell) cell.terrain = TerrainType.Crater;

            const success = manager.placeZone(5, 5, ZoneType.Residential);
            expect(success).toBe(false);
            expect(manager.zones.length).toBe(0);
        });

        it('should clear an entire 3x3 zone if any part is bulldozed', () => {
            manager.placeZone(5, 5, ZoneType.Residential);
            
            // Bulldoze an edge
            const success = manager.clearZone(4, 4);
            expect(success).toBe(true);
            
            expect(manager.grid.getCell(5, 5)?.zone).toBe(ZoneType.Empty);
            expect(manager.grid.getCell(6, 6)?.zoneEntity).toBeNull();
            expect(manager.zones.length).toBe(0);
        });
    });

    describe('Micro Zones (1x1)', () => {
        it('should place a 1x1 DroneStation as an entity', () => {
            const success = manager.placeZone(10, 10, ZoneType.DroneStation);
            expect(success).toBe(true);

            const center = manager.grid.getCell(10, 10);
            expect(center?.zone).toBe(ZoneType.DroneStation);
            expect(center?.zoneEntity).toBeDefined();
            expect(manager.zones.length).toBe(1);
        });

        it('should fail DroneStation placement on crater', () => {
            const cell = manager.grid.getCell(10, 10);
            if (cell) cell.terrain = TerrainType.Crater;

            const success = manager.placeZone(10, 10, ZoneType.DroneStation);
            expect(success).toBe(false);
        });

        it('should place Transit (Roads)', () => {
            const success = manager.placeZone(2, 2, ZoneType.Transit);
            expect(success).toBe(true);
            
            const cell = manager.grid.getCell(2, 2);
            expect(cell?.zone).toBe(ZoneType.Transit);
            expect(cell?.zoneEntity).toBeNull(); // Transit doesn't have an entity
            expect(manager.zones.length).toBe(0);
        });

        it('should fail Transit placement if an entity is already there', () => {
            manager.placeZone(5, 5, ZoneType.Residential);
            const success = manager.placeZone(5, 5, ZoneType.Transit);
            expect(success).toBe(false);
        });

        it('should fail Transit placement if a Transit is already there', () => {
            manager.placeZone(5, 5, ZoneType.Transit);
            const success = manager.placeZone(5, 5, ZoneType.Transit);
            expect(success).toBe(false);
        });

        it('should place PowerLine', () => {
            const success = manager.placeZone(3, 3, ZoneType.PowerLine);
            expect(success).toBe(true);
            
            const cell = manager.grid.getCell(3, 3);
            expect(cell?.hasPowerLine).toBe(true);
            expect(cell?.zone).toBe(ZoneType.Empty);
        });

        it('should fail PowerLine placement if an entity is already there', () => {
            manager.placeZone(5, 5, ZoneType.Residential);
            const success = manager.placeZone(5, 5, ZoneType.PowerLine);
            expect(success).toBe(false);
        });

        it('should fail PowerLine placement if a PowerLine is already there', () => {
            manager.placeZone(5, 5, ZoneType.PowerLine);
            const success = manager.placeZone(5, 5, ZoneType.PowerLine);
            expect(success).toBe(false);
        });

        it('should clear PowerLine', () => {
            manager.placeZone(3, 3, ZoneType.PowerLine);
            const success = manager.clearZone(3, 3);
            expect(success).toBe(true);
            
            const cell = manager.grid.getCell(3, 3);
            expect(cell?.hasPowerLine).toBe(false);
        });

        it('should return false when clearing empty cell', () => {
            const success = manager.clearZone(8, 8);
            expect(success).toBe(false);
        });
        
        it('should return false for out of bounds placement/clear', () => {
            expect(manager.placeZone(-1, -1, ZoneType.Transit)).toBe(false);
            expect(manager.clearZone(-1, -1)).toBe(false);
        });
    });
});
