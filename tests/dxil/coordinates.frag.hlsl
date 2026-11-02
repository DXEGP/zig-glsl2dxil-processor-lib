cbuffer GlCompat : register(b0, space1) { float4 transform; uint4 draw_state; }
struct Input { float4 position : SV_Position; nointerpolation int instance : TEXCOORD0; nointerpolation int vertex : TEXCOORD1; bool front : SV_IsFrontFace; };
struct Output { float4 first : SV_Target0; float4 second : SV_Target1; float depth : SV_Depth; };
Output main(Input input) {
    Output output;
    output.first = float4(input.position.x / 16, (transform.w - input.position.y) / 16, input.position.z, input.front ? 1 : 0);
    output.second = float4(float(input.instance), 1 / input.position.w, float(input.vertex), 1);
    output.depth = input.position.z;
    return output;
}
