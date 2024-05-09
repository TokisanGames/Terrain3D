// WORLD_NOISE1

//float hashv2(vec2 v) {
//	return fract(1e4 * sin(17.0 * v.x + v.y * 0.1) * (0.1 + abs(sin(v.y * 13.0 + v.x)))); }
	
// Explicitly Optimized - changes made should have (mostly) already been inlined by the compiler but why take chances.
float ihashv2(ivec2 iv) {  
	vec2 v = sin( vec2( iv * ivec2(17, 13) ) + vec2( float(iv.y) * 0.1, float(iv.x) ) );
	v.y = ( abs(v.y) + 0.1 );
	return fract( 1e4 * v.x * v.y ); }

// alternate optimization, unclear which performs better between this and above.
//float hashv2(ivec2 iv) {
//	vec2 v = vec2(iv);
//	v = sin( vec2(
//		fma( 17., v.x, v.y * 0.1 ),
//		fma( 13., v.y, v.x ) ) );
//	return fract( 1e4 * v.x * ( 0.1 + abs(v.y) ) ); }

/* vec3 orig_noise2D(vec2 x) {
    vec2 f = fract(x);
    // Quintic Hermine Curve.  Similar to SmoothStep()
    vec2 u = f*f*f*(f*(f*6.0-15.0)+10.0);
    vec2 du = 30.0*f*f*((f*f)-(f*2.0)+1.0);		
    // vec2 du = 30.0*f*f*(f*(f-2.0)+1.0);  // Original

    vec2 p = floor(x);

	// Four corners in 2D of a tile
	float a = hashv2( p+vec2(0,0) );
    float b = hashv2( p+vec2(1,0) );
    float c = hashv2( p+vec2(0,1) );
    float d = hashv2( p+vec2(1,1) );

    // Mix 4 corner percentages
    float k0 =   a;
    float k1 =   b - a;
    float k2 =   c - a;
    float k3 =   a - b - c + d;
    return vec3( k0 + k1 * u.x + k2 * u.y + k3 * u.x * u.y,
                du * ( vec2(k1, k2) + k3 * u.yx) ); } */

// https://iquilezles.org/articles/morenoise/
// Explicitly Optimized - changes made should already be in effect from compiler optimization but that's not always the case.
vec3 noise2D(vec2 x) {  
	const ivec2 i01 = ivec2(0,1);

    vec2 f = fract(x);
    // Quintic Hermine Curve.  Similar to SmoothStep()
	vec2 f2 = f*f;
    vec4 udu = f2.xyxy * vec4(
		f * (fma(f, (fma(f, vec2(6.0), -vec2(15.0))), vec2(10.0))),
    	30.0 * (fma (f, (f - 2.0), vec2(1.0))));
    ivec2 p = ivec2(floor(x));

	// Four corners in 2D of a tile
	vec4 abcd = vec4( ihashv2(p), ihashv2(p + i01.yx), ihashv2(p + i01.xy), ihashv2(p + 1)	);

    // Mix 4 corner percentages
	vec3 k123 = abcd.yzx - abcd.xxy;
	k123.z = k123.z - abcd.z + abcd.w;
	udu.zw *= fma(udu.yx, k123.zz, k123.xy);
	k123 *= udu.xyx;
    return vec3( fma(k123.z, udu.y, abcd.x + k123.x + k123.y), udu.zw ); }

float bg_world(vec2 p) {
    float a = 0.0;
    float b = 1.0;
    vec2  d = vec2(0.0);
    int octaves = int( clamp(
	float(_bg_world_max_octaves) - floor(v_vertex_xz_dist/(_bg_world_lod_distance)),
    float(_bg_world_min_octaves), float(_bg_world_max_octaves)) );
    for( int i=0; i < octaves; i++ ) {
        vec3 n = noise2D(p);
        d += n.yz;
        a += b * n.x / (1.0 + dot(d,d));
        b *= 0.5;
        p = mat2( vec2(0.8, -0.6), vec2(0.6, 0.8) ) * p * 2.0; }
    return a; }

// World Noise end