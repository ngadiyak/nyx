enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance {
        float2 pos;
        float2 size;
        float2 uv0;
        float2 uv1;
        float4 color;
        uint kind;
        uint p0; uint p1; uint p2;
    };

    struct Uniforms {
        float2 viewport;
        float atlasSize;
        float pad;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
        float2 local;
        float4 color;
        uint kind [[flat]];
    };

    vertex VOut nyx_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device Instance* instances [[buffer(0)]],
                           constant Uniforms& u [[buffer(1)]]) {
        Instance i = instances[iid];
        float2 corner = float2(float(vid & 1u), float(vid >> 1u));
        float2 px = i.pos + corner * i.size;
        float2 ndc = float2(px.x / u.viewport.x * 2.0 - 1.0, 1.0 - px.y / u.viewport.y * 2.0);
        VOut o;
        o.position = float4(ndc, 0.0, 1.0);
        o.uv = (i.uv0 + corner * (i.uv1 - i.uv0)) / u.atlasSize;
        o.local = corner;
        o.color = i.color;
        o.kind = i.kind;
        return o;
    }

    fragment float4 nyx_fragment(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(mag_filter::nearest, min_filter::nearest);
        switch (in.kind) {
        case 0: return in.color;
        case 1: { float a = atlas.sample(s, in.uv).a; return float4(in.color.rgb * a, a); }
        case 2: return atlas.sample(s, in.uv);
        case 3: {
            float wave = 0.5 + 0.35 * sin(in.local.x * 6.2831853 * 2.0);
            float a = 1.0 - smoothstep(0.15, 0.3, abs(in.local.y - wave));
            return float4(in.color.rgb * a, a);
        }
        case 4: { float a = fract(in.local.x * 4.0) < 0.5 ? 1.0 : 0.0; return float4(in.color.rgb * a, a); }
        case 5: { float a = fract(in.local.x * 2.0) < 0.6 ? 1.0 : 0.0; return float4(in.color.rgb * a, a); }
        default: return in.color;
        }
    }
    """
}
