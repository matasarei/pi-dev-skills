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

    describe('Funds', () => {
        it('should start with 2000 funds by default', () => {
            const manager = new CityManager(20, 20, false);
            // Clear the auto-spawned LandingBase (costs 0)
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);
            expect(manager.funds).toBe(2000);
        });

        it('should accept a custom starting funds amount', () => {
            const manager = new CityManager(20, 20, false, 500);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);
            expect(manager.funds).toBe(500);
        });

        it('should subtract cost on successful placement', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            const cost = 100; // Residential
            manager.placeZone(5, 5, ZoneType.Residential);
            expect(manager.funds).toBe(2000 - cost);
        });

        it('should refuse placement when funds are insufficient', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            // Only 50 funds, but Residential costs 100
            manager.funds = 50;
            const success = manager.placeZone(5, 5, ZoneType.Residential);
            expect(success).toBe(false);
            // Grid and zones should be unchanged
            expect(manager.zones.length).toBe(0);
            expect(manager.grid.getCell(5, 5)?.zone).toBe(ZoneType.Empty);
        });

        it('should not charge when placement fails for other reasons', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            // Place a crater at the target
            const cell = manager.grid.getCell(5, 5);
            if (cell) cell.terrain = TerrainType.Crater;

            const initialFunds = manager.funds;
            const success = manager.placeZone(5, 5, ZoneType.Residential);
            expect(success).toBe(false);
            // Funds should be unchanged since placement failed
            expect(manager.funds).toBe(initialFunds);
        });

        it('should allow placement with exactly enough funds', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            // Exactly 100 funds for a Residential zone
            manager.funds = 100;
            const success = manager.placeZone(5, 5, ZoneType.Residential);
            expect(success).toBe(true);
            expect(manager.funds).toBe(0);
        });

        it('should not charge for LandingBase placement', () => {
            const manager = new CityManager(20, 20, false);
            // LandingBase costs 0, so funds should be unchanged
            const initialFunds = manager.funds;
            manager.placeZone(10, 10, ZoneType.LandingBase);
            expect(manager.funds).toBe(initialFunds);
        });

        it('should not charge for Transit placement', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            const initialFunds = manager.funds;
            manager.placeZone(5, 5, ZoneType.Transit);
            expect(manager.funds).toBe(initialFunds - 10); // Transit costs 10
        });

        it('should not charge for PowerLine placement', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            const initialFunds = manager.funds;
            manager.placeZone(5, 5, ZoneType.PowerLine);
            expect(manager.funds).toBe(initialFunds - 5); // PowerLine costs 5
        });

        it('should not charge for DroneStation placement', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            const initialFunds = manager.funds;
            manager.placeZone(5, 5, ZoneType.DroneStation);
            expect(manager.funds).toBe(initialFunds - 50); // DroneStation costs 50
        });

        it('should not charge for Launchpad placement', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            const initialFunds = manager.funds;
            manager.placeZone(5, 5, ZoneType.Launchpad);
            expect(manager.funds).toBe(initialFunds - 1000); // Launchpad costs 1000
        });

        it('should not charge for PowerPlant placement', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            const initialFunds = manager.funds;
            manager.placeZone(5, 5, ZoneType.PowerPlant);
            expect(manager.funds).toBe(initialFunds - 500); // PowerPlant costs 500
        });

        it('should not charge for Hospital placement', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            const initialFunds = manager.funds;
            manager.placeZone(5, 5, ZoneType.Hospital);
            expect(manager.funds).toBe(initialFunds - 400); // Hospital costs 400
        });

        it('should not charge for PoliceStation placement', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            const initialFunds = manager.funds;
            manager.placeZone(5, 5, ZoneType.PoliceStation);
            expect(manager.funds).toBe(initialFunds - 300); // PoliceStation costs 300
        });

        it('should not charge for MaintenanceDepot placement', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            const initialFunds = manager.funds;
            manager.placeZone(5, 5, ZoneType.MaintenanceDepot);
            expect(manager.funds).toBe(initialFunds - 250); // MaintenanceDepot costs 250
        });

        it('should not charge for Commercial placement', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            const initialFunds = manager.funds;
            manager.placeZone(5, 5, ZoneType.Commercial);
            expect(manager.funds).toBe(initialFunds - 150); // Commercial costs 150
        });

        it('should not charge for Industrial placement', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            const initialFunds = manager.funds;
            manager.placeZone(5, 5, ZoneType.Industrial);
            expect(manager.funds).toBe(initialFunds - 200); // Industrial costs 200
        });

        it('should not charge for Residential placement', () => {
            const manager = new CityManager(20, 20, false);
            const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
            if (base) manager.clearZone(base.centerX, base.centerY);

            const initialFunds = manager.funds;
            manager.placeZone(5, 5, ZoneType.Residential);
            expect(manager.funds).toBe(initialFunds - 100); // Residential costs 100
        });

    });
});
