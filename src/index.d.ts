/* eslint-disable prettier/prettier */
declare class CullThrottle {
    constructor()

    // TODO: ObjectEntered & Exited view? 

    AddObject(object: Instance): void
    AddPhysicsObject(object: BasePart): void
    RemoveObject(object: Instance): void

    CaptureTag(tag: string): void
    ReleaseTag(tag: string): void
    RemoveObjectsWithTag(tag: string): void

    GetVisibleObjects(): Instance[]
    IterateObjectsToUpdate(): IterableFunction<[Instance, number, number]>

    SetVoxelSize(voxelSize: number): void
    SetRenderDistanceTarget(renderDistanceTarget: number): void

    SetTimeBudgets(searchTimeBudget: number, ingestTimeBudget: number, updateTimeBudget: number): void
    SetRefreshRates(best: number, worst: number): void

    SetComputeVisibilityOnlyOnDemand(computeVisibilityOnlyOnDemand: boolean): void
    SetStrictlyEnforcedWorstRefreshRate(strictlyEnforceWorstRefreshRate: boolean): void
    SetDynamicRenderDistance(dynamicRenderDistance: boolean): void
}


export default CullThrottle;
