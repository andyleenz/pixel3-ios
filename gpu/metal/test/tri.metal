// tri.metal - the smallest draw for mtl-draw's frontend check: one full-viewport triangle in one colour.
#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; };
vertex V tri_v(uint vid [[vertex_id]]) {
	const float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
	V o; o.pos = float4(p[vid], 0, 1); return o;
}
fragment float4 tri_f(V in [[stage_in]]) { return float4(1, 0.5, 0, 1); }
