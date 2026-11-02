cbuffer GlCompat : register(b0, space1) { float4 transform; uint4 draw_state; }
struct Input { float4 position : TEXCOORD0; uint instance : SV_InstanceID; uint vertex : SV_VertexID; };
struct Output { float4 position : SV_Position; nointerpolation int instance : TEXCOORD0; nointerpolation int vertex : TEXCOORD1; };
Output main(Input input) {
    Output output;
    output.position = input.position;
    output.position.y *= transform.x;
    output.position.z = input.position.z * transform.y + input.position.w * transform.z;
    output.instance = int(input.instance - draw_state.x);
    output.vertex = int(input.vertex);
    return output;
}
