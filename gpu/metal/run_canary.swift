// Executes the atlas canary pair on this machine's GPU.
//
// Fills a real 3D r32Uint texture through the same addressing helper the shipping
// path uses, then reads every texel back and checks it. This exercises the physical
// atlas mapping (page id -> 3D slot -> texel) on hardware, including the slot
// factorisation the planner produced.
//
// Usage: run_canary <write.msl> <check.msl> <page_count> <slots_x> <slots_y> <slots_z>

import Foundation
import Metal

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 7 else {
    fail("usage: run_canary <write.msl> <check.msl> <page_count> <slots_x> <slots_y> <slots_z>")
}
guard let writeSource = try? String(contentsOfFile: args[1], encoding: .utf8),
      let checkSource = try? String(contentsOfFile: args[2], encoding: .utf8) else {
    fail("cannot read shader sources")
}
guard let pageCount = Int(args[3]), let slotsX = Int(args[4]),
      let slotsY = Int(args[5]), let slotsZ = Int(args[6]) else {
    fail("bad numeric arguments")
}

guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }

func makePipeline(_ source: String, _ label: String) -> MTLComputePipelineState {
    do {
        let lib = try device.makeLibrary(source: source, options: nil)
        guard let fn = lib.makeFunction(name: "main0") else { fail("\(label): main0 missing") }
        return try device.makeComputePipelineState(function: fn)
    } catch {
        fail("\(label): \(error)")
    }
}

let writePipeline = makePipeline(writeSource, "write")
let checkPipeline = makePipeline(checkSource, "check")

let texW = slotsX * 8, texH = slotsY * 8, texD = slotsZ * 8
let desc = MTLTextureDescriptor()
desc.textureType = .type3D
desc.pixelFormat = .r32Uint
desc.width = texW
desc.height = texH
desc.depth = texD
desc.usage = [.shaderRead, .shaderWrite]
desc.storageMode = .private
guard let atlas = device.makeTexture(descriptor: desc) else { fail("atlas allocation failed") }

var pc = [UInt32](repeating: 0, count: 4)
pc[0] = UInt32(pageCount)
pc[1] = UInt32(slotsX)
pc[2] = UInt32(slotsY)
pc[3] = 0

guard let resultBuffer = device.makeBuffer(length: 16, options: .storageModeShared) else {
    fail("result allocation failed")
}
memset(resultBuffer.contents(), 0, 16)

guard let queue = device.makeCommandQueue() else { fail("no queue") }

// Pass 1: write.
let total = pageCount * 512
let groups = (total + 63) / 64
guard let cmd1 = queue.makeCommandBuffer(), let enc1 = cmd1.makeComputeCommandEncoder() else {
    fail("encode failed")
}
enc1.setComputePipelineState(writePipeline)
enc1.setBytes(pc, length: 16, index: 0)
enc1.setTexture(atlas, index: 0)
enc1.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
enc1.endEncoding()
cmd1.commit()
cmd1.waitUntilCompleted()
if let e = cmd1.error { fail("write pass: \(e)") }

// Pass 2: check.
guard let cmd2 = queue.makeCommandBuffer(), let enc2 = cmd2.makeComputeCommandEncoder() else {
    fail("encode failed")
}
enc2.setComputePipelineState(checkPipeline)
enc2.setBytes(pc, length: 16, index: 0)
enc2.setBuffer(resultBuffer, offset: 0, index: 1)
enc2.setTexture(atlas, index: 0)
enc2.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
enc2.endEncoding()
cmd2.commit()
cmd2.waitUntilCompleted()
if let e = cmd2.error { fail("check pass: \(e)") }

let r = resultBuffer.contents().bindMemory(to: UInt32.self, capacity: 4)
let mismatches = r[0]

print("device      : \(device.name)")
print("atlas       : \(texW)x\(texH)x\(texD) r32Uint (\(texW * texH * texD * 4 / 1024) KiB)")
print("pages       : \(pageCount) (\(total) texels)")
print("groups      : \(groups)")
if mismatches == 0 {
    print("RESULT      : PASS - 0 mismatches")
    exit(0)
} else {
    print("RESULT      : FAIL - \(mismatches) mismatches, first page \(r[1]) local \(r[2])")
    exit(1)
}
