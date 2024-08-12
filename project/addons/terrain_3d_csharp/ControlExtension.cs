using System;

namespace Terrain3DExtensions;

public static class ControlExtension
{
    public static byte GetBaseTextureId(this uint control)
        => (byte)(control >> 27 & 0x1F);

    public static void SetBaseTextureId(this ref uint control, byte baseTextureId)
        => control = (control & ~((uint)0x1F << 27)) | (uint)((baseTextureId & 0x1F) << 27);

    public static byte GetOverlayTextureId(this uint control)
        => (byte)(control >> 22 & 0x1F);

    public static void SetOverlayTextureId(this ref uint control, byte overLayTextureId)
    {
        control = (control & ~((uint)0x1F << 22)) | (uint)((overLayTextureId & 0x1F) << 22);

        // control &= ~((uint)0x1F << 22);
        // control |= (uint)((overLayTextureId & 0x1F) << 22);
    }

    public static byte GetTextureBlend(this uint control)
        => (byte)(control >> 14 & 0xFF);

    public static void SetTextureBlend(this ref uint control, byte blend)
        => control = (control & ~((uint)0xFF << 14)) | (uint)((blend & 0xFF) << 14);

    public static byte GetUvAngle(this uint control)
        => (byte)(control >> 10 & 0xF);

    public static void SetUvAngle(this ref uint control, byte uVAngle)
        => control = (control & ~((uint)0xF << 10)) | (uint)((uVAngle & 0xF) << 10);

    public static byte GetUvScale(this uint control) 
        => (byte)(control >> 6 & 0x7);

    public static void SetUvScale(this ref uint control, byte uvScale) 
        => control = (control & ~((uint)0x7 << 6)) | (uint)((uvScale & 0x7) << 6);

    public static bool IsHole(this uint control) 
        => Convert.ToBoolean(control >> 2 & 0x1);

    public static void SetHole(this ref uint control, bool hole) 
        => control = (control & ~((uint)0x1 << 2)) | (uint)((hole ? 1 : 0) << 2);

    public static bool IsNavigation(this uint control) 
        => Convert.ToBoolean(control >> 1 & 0x1);

    public static void SetNavigation(this ref uint control, bool navigation) 
        => control = (control & ~((uint)0x1 << 1)) | (uint)((navigation ? 1 : 0) << 1);

    public static bool IsAutoshaded(this uint control) 
        => Convert.ToBoolean(control & 0x1);

    public static void SetAutoshaded(this ref uint control, bool autoShaded) 
        => control = (control & ~(uint)0x1) | (uint)(autoShaded ? 1 : 0);
}