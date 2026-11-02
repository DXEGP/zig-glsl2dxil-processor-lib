uniform vec4 a;
uniform vec4 b;
uniform ivec4 integers;
uniform ivec4 shifts;
out vec4 c;

void main() {
    vec2 x = a.yx + b.zw;
    vec3 y = a.xyz * b.zyx;
    vec4 d = (a + b) / 2.0;
    ivec4 z = (integers << shifts) ^ ivec4(3);
    c = vec4(x.x, y.y, float(z.z), d.w);
}
