#pragma once

#ifndef TERRAIN3D_PROPSET_MACROS_H
#define TERRAIN3D_PROPSET_MACROS_H

//Code Templates for Terrain3D Managed GLSL/Godot Properties

// ################################################################################
#pragma region _core_management_macros_

	#define PASS_NX(A, B) A ## B
	#define PASS(A, B) PASS_NX(A, B)
	#define TOKETOKE_NX(A) #A
	#define TOKETOKE(A) TOKETOKE_NX(A)

	#define BIND_HELP(m_help_id) \
		ClassDB::bind_method(D_METHOD(TOKETOKE(PASS(_get_help_with_, m_help_id))), &Terrain3DMaterial::_get_help_with_##m_help_id); \

#ifdef __TEMPORARY_INLINE_HELP
	#define ADD_INLINE_HELP(m_help_id, m_path_prefix, m_heading_desc) \
		ClassDB::bind_method( D_METHOD( TOKETOKE(PASS(get_help_with_, m_help_id) ) ), &Terrain3DMaterial::_get_help_with_##m_help_id ); \
		ClassDB::add_property(get_class_static(), PropertyInfo(Variant::STRING, TOKETOKE(PASS(m_path_prefix##/Help/, m_heading_desc##:)), PROPERTY_HINT_MULTILINE_TEXT ), "", TOKETOKE(PASS(get_help_with_, m_help_id)));

	#define ADD_HELP_TOPIC_DECL(helpID, contents) \
		String _get_help_with_##helpID() const { return Terrain3DMaterial::_format_string_for_inline_help(String(contents)); }
#else
	#define ADD_INLINE_HELP(m_help_id, m_path_prefix, m_heading_desc) 
	#define ADD_HELP_TOPIC_DECL(helpID, contents) 
#endif

	#define ADD_BIND(m_bind_id, m_param_label) \
		ClassDB::bind_method(D_METHOD((TOKETOKE(PASS(get_, m_bind_id)))), &Terrain3DMaterial::get_##m_bind_id); \
		ClassDB::bind_method(D_METHOD(TOKETOKE(PASS(set_, m_bind_id)), #m_param_label), &Terrain3DMaterial::set_##m_bind_id);

	#define ADD_PRIV_BIND(m_bind_id, m_param_label) \
		ClassDB::bind_method(D_METHOD((TOKETOKE(PASS(_get_, m_bind_id)))), &Terrain3DMaterial::_get_##m_bind_id); \
		ClassDB::bind_method(D_METHOD(TOKETOKE(PASS(_set_, m_bind_id)), #m_param_label), &Terrain3DMaterial::_set_##m_bind_id);

	#define ADD_METHOD(m_bind_id, ...) \
		ClassDB::bind_method(D_METHOD(TOKETOKE_NX(m_bind_id), #__VA_ARGS__), &Terrain3DMaterial::##m_bind_id);

	#define ADD_METHOD_NOP( m_bind_id ) \
		ClassDB::bind_method(D_METHOD(TOKETOKE_NX(m_bind_id) ), &Terrain3DMaterial::##m_bind_id);

	#define __PROP_GEN(m_member_id, m_var_type, ...) ADD_PROPERTY(PropertyInfo(Variant::m_var_type, #m_member_id, PROPERTY_HINT_##__VA_ARGS__##),TOKETOKE(PASS(set_, m_member_id)) ,TOKETOKE(PASS(get_, m_member_id)));
	#define __PROP_GENGRP(m_group_id, m_member_id, m_var_type, ...) __PROP_GEN(m_group_id##_##m_member_id, m_var_type,__VA_ARGS__)

	#define VARR(m_bind_id, m_type, m_value) m_type _##m_bind_id = m_value;
	#define SETR(m_bind_id, m_type) void set_##m_bind_id(m_type p_value)
	#define GETR(m_bind_id, m_type) m_type get_##m_bind_id() const { return _##m_bind_id; }

	#define GSTR(m_bind_id, m_type) \
	GETR(m_bind_id, m_type); \
	SETR(m_bind_id, m_type);

	#define GROUP_VARS(m_bind_id) void _update_##m_bind_id##_params();
	#define UPDATE_GROUP(m_bind_id) _update_##m_bind_id##_params();

	//	LOG(INFO, s_log_desc, p_value) 
	#define __SETC__(m_bind_id, m_type, s_log_desc, f_after) \
	void Terrain3DMaterial::set_##m_bind_id(m_type p_value) { \
		LOG(INFO, s_log_desc, _##m_bind_id);\
		_##m_bind_id = p_value; \
		f_after; }

	#define SETUPD__GRP(m_group_id, m_member_id, m_type, s_log_desc) __SETC__(m_member_id, m_type, s_log_desc, _update_shader() )
	#define __SETPR_GRP(m_group_id, m_member_id, m_type, s_log_desc) __SETC__(m_member_id, m_type, s_log_desc, _update_##m_group_id##_params() )
	#define UPDATE_SHADER(mbind_id) _safe_material_set_param("_" #mbind_id, _##mbind_id);

	#define UPDATE_GRP_START(m_group_id) \
	void Terrain3DMaterial::_update_##m_group_id##_params() { \
		if (_##m_group_id##_enabled && _material != Variant::NIL) { 

	#define UPDATE_GRP_START_CON(m_group_id, m_condition) \
		void Terrain3DMaterial::_update_##m_group_id##_params() { \
			if (( m_condition ) && ( _material != Variant::NIL) ) {

	#define UPDATE_GRP_END() } }

// Boolean debug view updates trigger shader recompilation
#define UPDATE_DEBUG_OPT(mbind_id) \
	void Terrain3DMaterial::set_debug_view_##mbind_id##(bool p_enabled) {\
	_debug_view_##mbind_id## = p_enabled;\
	_update_shader(); }
// Float and Vec3 debug view property updates do not trigger recompilation, 
// they set the corresponding uniform value directly.
#define UPDATE_DEBUG_VEC3(mbind_id) \
	void Terrain3DMaterial::set_debug_view_##mbind_id##(Vector3 p_vec) {\
	_debug_view_##mbind_id## = p_vec;\
	_update_debug_view_params(); }
#define UPDATE_DEBUG_FLOAT(mbind_id) \
	void Terrain3DMaterial::set_debug_view_##mbind_id##(float p_float) {\
	_debug_view_##mbind_id## = p_float;\
	_update_debug_view_params(); }
#pragma endregion _core_management_macros_
// ################################################################################

#endif