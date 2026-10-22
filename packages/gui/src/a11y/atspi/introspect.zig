//! AT-SPI2 introspection data (E04.F09.S01.T03): the XML of each
//! interface the bridge serves (the subset of at-spi2-core's xml/ it
//! implements), joined per object by `xml`.

const std = @import("std");
const roles = @import("roles.zig");

const header =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\ "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\
;

const common =
    \\<interface name="org.freedesktop.DBus.Introspectable"><method name="Introspect"><arg direction="out" type="s"/></method></interface>
    \\<interface name="org.freedesktop.DBus.Properties">
    \\<method name="Get"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="out" type="v"/></method>
    \\<method name="GetAll"><arg direction="in" type="s"/><arg direction="out" type="a{sv}"/></method>
    \\<method name="Set"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="in" type="v"/></method>
    \\</interface>
    \\
;

/// Each interface's XML, in `roles.Ifaces.names` order.
pub const ifaces = [_][]const u8{
    \\<interface name="org.a11y.atspi.Accessible">
    \\<property name="Name" type="s" access="read"/><property name="Description" type="s" access="read"/>
    \\<property name="Parent" type="(so)" access="read"/><property name="ChildCount" type="i" access="read"/>
    \\<property name="Locale" type="s" access="read"/><property name="AccessibleId" type="s" access="read"/>
    \\<property name="HelpText" type="s" access="read"/>
    \\<method name="GetChildAtIndex"><arg direction="in" type="i"/><arg direction="out" type="(so)"/></method>
    \\<method name="GetChildren"><arg direction="out" type="a(so)"/></method>
    \\<method name="GetIndexInParent"><arg direction="out" type="i"/></method>
    \\<method name="GetRelationSet"><arg direction="out" type="a(ua(so))"/></method>
    \\<method name="GetRole"><arg direction="out" type="u"/></method>
    \\<method name="GetRoleName"><arg direction="out" type="s"/></method>
    \\<method name="GetLocalizedRoleName"><arg direction="out" type="s"/></method>
    \\<method name="GetState"><arg direction="out" type="au"/></method>
    \\<method name="GetAttributes"><arg direction="out" type="a{ss}"/></method>
    \\<method name="GetApplication"><arg direction="out" type="(so)"/></method>
    \\<method name="GetInterfaces"><arg direction="out" type="as"/></method>
    \\</interface>
    \\
    ,
    \\<interface name="org.a11y.atspi.Application">
    \\<property name="ToolkitName" type="s" access="read"/><property name="Version" type="s" access="read"/>
    \\<property name="AtspiVersion" type="s" access="read"/><property name="Id" type="i" access="readwrite"/>
    \\<method name="GetLocale"><arg direction="in" type="u"/><arg direction="out" type="s"/></method>
    \\</interface>
    \\
    ,
    \\<interface name="org.a11y.atspi.Component">
    \\<method name="Contains"><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="in" type="u"/><arg direction="out" type="b"/></method>
    \\<method name="GetAccessibleAtPoint"><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="in" type="u"/><arg direction="out" type="(so)"/></method>
    \\<method name="GetExtents"><arg direction="in" type="u"/><arg direction="out" type="(iiii)"/></method>
    \\<method name="GetPosition"><arg direction="in" type="u"/><arg direction="out" type="i"/><arg direction="out" type="i"/></method>
    \\<method name="GetSize"><arg direction="out" type="i"/><arg direction="out" type="i"/></method>
    \\<method name="GetLayer"><arg direction="out" type="u"/></method>
    \\<method name="GetMDIZOrder"><arg direction="out" type="n"/></method>
    \\<method name="GrabFocus"><arg direction="out" type="b"/></method>
    \\<method name="GetAlpha"><arg direction="out" type="d"/></method>
    \\<method name="ScrollTo"><arg direction="in" type="u"/><arg direction="out" type="b"/></method>
    \\</interface>
    \\
    ,
    \\<interface name="org.a11y.atspi.Action">
    \\<property name="NActions" type="i" access="read"/>
    \\<method name="GetDescription"><arg direction="in" type="i"/><arg direction="out" type="s"/></method>
    \\<method name="GetName"><arg direction="in" type="i"/><arg direction="out" type="s"/></method>
    \\<method name="GetLocalizedName"><arg direction="in" type="i"/><arg direction="out" type="s"/></method>
    \\<method name="GetKeyBinding"><arg direction="in" type="i"/><arg direction="out" type="s"/></method>
    \\<method name="GetActions"><arg direction="out" type="a(sss)"/></method>
    \\<method name="DoAction"><arg direction="in" type="i"/><arg direction="out" type="b"/></method>
    \\</interface>
    \\
    ,
    \\<interface name="org.a11y.atspi.Value">
    \\<property name="MinimumValue" type="d" access="read"/><property name="MaximumValue" type="d" access="read"/>
    \\<property name="MinimumIncrement" type="d" access="read"/><property name="CurrentValue" type="d" access="readwrite"/>
    \\<property name="Text" type="s" access="read"/>
    \\</interface>
    \\
    ,
    \\<interface name="org.a11y.atspi.Text">
    \\<property name="CharacterCount" type="i" access="read"/><property name="CaretOffset" type="i" access="read"/>
    \\<method name="GetText"><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="out" type="s"/></method>
    \\<method name="GetStringAtOffset"><arg direction="in" type="i"/><arg direction="in" type="u"/><arg direction="out" type="s"/><arg direction="out" type="i"/><arg direction="out" type="i"/></method>
    \\<method name="GetCharacterAtOffset"><arg direction="in" type="i"/><arg direction="out" type="i"/></method>
    \\<method name="GetCharacterExtents"><arg direction="in" type="i"/><arg direction="in" type="u"/><arg direction="out" type="i"/><arg direction="out" type="i"/><arg direction="out" type="i"/><arg direction="out" type="i"/></method>
    \\<method name="GetNSelections"><arg direction="out" type="i"/></method>
    \\<method name="GetSelection"><arg direction="in" type="i"/><arg direction="out" type="i"/><arg direction="out" type="i"/></method>
    \\</interface>
    \\
    ,
    \\<interface name="org.a11y.atspi.Selection">
    \\<property name="NSelectedChildren" type="i" access="read"/>
    \\<method name="GetSelectedChild"><arg direction="in" type="i"/><arg direction="out" type="(so)"/></method>
    \\<method name="SelectChild"><arg direction="in" type="i"/><arg direction="out" type="b"/></method>
    \\<method name="DeselectSelectedChild"><arg direction="in" type="i"/><arg direction="out" type="b"/></method>
    \\<method name="IsChildSelected"><arg direction="in" type="i"/><arg direction="out" type="b"/></method>
    \\<method name="SelectAll"><arg direction="out" type="b"/></method>
    \\<method name="ClearSelection"><arg direction="out" type="b"/></method>
    \\<method name="DeselectChild"><arg direction="in" type="i"/><arg direction="out" type="b"/></method>
    \\</interface>
    \\
    ,
};

comptime {
    std.debug.assert(ifaces.len == roles.Ifaces.names.len);
}

/// The introspection XML of an object serving `set`.
pub fn xml(a: std.mem.Allocator, set: roles.Ifaces) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, header);
    const bits: u8 = @bitCast(set);
    for (ifaces, 0..) |x, i| if (bits & (@as(u8, 1) << @intCast(i)) != 0) try out.appendSlice(a, x);
    try out.appendSlice(a, common);
    try out.appendSlice(a, "</node>\n");
    return out.items;
}
