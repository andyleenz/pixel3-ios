// MetalHello's shaders: a triangle turned by an angle, one colour per corner.
#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float4 color; };
vertex V spin_v(uint vid [[vertex_id]], constant float &angle [[buffer(0)]]) {
	const float2 p[3] = { float2(0, 0.6), float2(-0.52, -0.3), float2(0.52, -0.3) };
	const float4 c[3] = { float4(1, 0.3, 0.2, 1), float4(0.2, 0.9, 0.3, 1), float4(0.2, 0.4, 1, 1) };
	float s = sin(angle), k = cos(angle);
	float2 q = float2(p[vid].x * k - p[vid].y * s, p[vid].x * s + p[vid].y * k);
	V o; o.pos = float4(q.x, q.y * 0.5, 0, 1); o.color = c[vid]; return o;
}
fragment float4 spin_f(V in [[stage_in]]) { return in.color; }
