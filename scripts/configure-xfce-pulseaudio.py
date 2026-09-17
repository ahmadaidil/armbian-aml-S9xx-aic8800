#!/usr/bin/env python3
import argparse
import os
import re
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


PLUGIN_PATTERN = re.compile(r"plugin-(\d+)$")
REQUIRED_BOOLEAN_PROPERTIES = (
    "enable-keyboard-shortcuts",
    "enable-multimedia-keys",
    "enable-mpris",
    "show-notifications",
)
RIGHT_ZONE_TYPES = (
    "pager",
    "separator",
    "systray",
    "pulseaudio",
    "separator",
    "actions",
    "separator",
    "clock",
)


def named_property(parent: ET.Element, name: str) -> ET.Element | None:
    for child in parent.findall("property"):
        if child.get("name") == name:
            return child
    return None


def panel_plugin_ids(panels: ET.Element) -> list[ET.Element]:
    arrays = []
    for panel in panels.findall("property"):
        plugin_ids = named_property(panel, "plugin-ids")
        if plugin_ids is not None:
            arrays.append(plugin_ids)
    return arrays


def plugin_number(plugin: ET.Element) -> int:
    match = PLUGIN_PATTERN.fullmatch(plugin.get("name", ""))
    if match is None:
        raise ValueError(f"invalid panel plugin name: {plugin.get('name')!r}")
    return int(match.group(1))


def set_property(parent: ET.Element, name: str, value_type: str, value: str) -> None:
    child = named_property(parent, name)
    if child is None:
        child = ET.SubElement(parent, "property", {"name": name})
    child.set("type", value_type)
    child.set("value", value)


def property_is_true(parent: ET.Element, name: str) -> bool:
    child = named_property(parent, name)
    return child is not None and child.get("type") == "bool" and child.get("value") == "true"


def plugin_map(plugins: ET.Element) -> dict[int, ET.Element]:
    return {
        plugin_number(plugin): plugin
        for plugin in plugins.findall("property")
        if PLUGIN_PATTERN.fullmatch(plugin.get("name", ""))
    }


def array_numbers(array: ET.Element) -> list[int]:
    return [int(value.get("value", "-1")) for value in array.findall("value") if value.get("type") == "int"]


def load_layout(path: Path) -> tuple[ET.ElementTree, ET.Element, ET.Element, list[ET.Element]]:
    tree = ET.parse(path)
    root = tree.getroot()
    panels = named_property(root, "panels")
    plugins = named_property(root, "plugins")
    if panels is None or plugins is None:
        raise ValueError(f"{path}: missing panels or plugins property")
    arrays = panel_plugin_ids(panels)
    if not arrays:
        raise ValueError(f"{path}: no panel plugin-ids array found")
    return tree, panels, plugins, arrays


def validate(path: Path) -> str:
    _, _, plugins, arrays = load_layout(path)
    pulse_plugins = [plugin for plugin in plugins.findall("property") if plugin.get("value") == "pulseaudio"]
    if len(pulse_plugins) != 1:
        raise ValueError(f"{path}: expected one pulseaudio plugin, found {len(pulse_plugins)}")

    pulse_plugin = pulse_plugins[0]
    pulse_number = plugin_number(pulse_plugin)
    referenced = any(
        any(value.get("type") == "int" and value.get("value") == str(pulse_number) for value in array.findall("value"))
        for array in arrays
    )
    if not referenced:
        raise ValueError(f"{path}: pulseaudio plugin-{pulse_number} is not referenced by a panel")

    for name in REQUIRED_BOOLEAN_PROPERTIES:
        prop = named_property(pulse_plugin, name)
        if prop is None or prop.get("type") != "bool" or prop.get("value") != "true":
            raise ValueError(f"{path}: {name} is not explicitly enabled")
    mixer = named_property(pulse_plugin, "mixer-command")
    if mixer is None or mixer.get("value") != "pavucontrol":
        raise ValueError(f"{path}: mixer-command is not pavucontrol")

    plugins_by_id = plugin_map(plugins)
    right_zone = array_numbers(arrays[0])[-len(RIGHT_ZONE_TYPES) :]
    right_zone_types = tuple(plugins_by_id[number].get("value", "") for number in right_zone)
    if right_zone_types != RIGHT_ZONE_TYPES:
        raise ValueError(f"{path}: unexpected right-side panel order: {right_zone_types}")

    actions = plugins_by_id[right_zone[5]]
    appearance = named_property(actions, "appearance")
    button_title = named_property(actions, "button-title")
    if appearance is None or appearance.get("type") != "uint" or appearance.get("value") != "1":
        raise ValueError(f"{path}: Action Buttons appearance is not Session Menu")
    if button_title is None or button_title.get("type") != "uint" or button_title.get("value") != "0":
        raise ValueError(f"{path}: Action Buttons title is not Full Name")

    for number in (right_zone[1], right_zone[4], right_zone[6]):
        separator = plugins_by_id[number]
        if property_is_true(separator, "expand"):
            raise ValueError(f"{path}: right-side separator plugin-{number} must not expand")
    return f"plugin-{pulse_number}"


def configure(path: Path) -> str:
    tree, _, plugins, arrays = load_layout(path)
    all_plugins = plugins.findall("property")
    pulse_plugins = [plugin for plugin in all_plugins if plugin.get("value") == "pulseaudio"]
    if len(pulse_plugins) > 1:
        raise ValueError(f"{path}: multiple pulseaudio plugins already exist")

    if pulse_plugins:
        pulse_plugin = pulse_plugins[0]
        pulse_number = plugin_number(pulse_plugin)
    else:
        used_numbers = [plugin_number(plugin) for plugin in all_plugins if PLUGIN_PATTERN.fullmatch(plugin.get("name", ""))]
        pulse_number = max(used_numbers, default=0) + 1
        pulse_plugin = ET.SubElement(
            plugins,
            "property",
            {"name": f"plugin-{pulse_number}", "type": "string", "value": "pulseaudio"},
        )

    for name in REQUIRED_BOOLEAN_PROPERTIES:
        set_property(pulse_plugin, name, "bool", "true")
    set_property(pulse_plugin, "mixer-command", "string", "pavucontrol")

    referenced = any(
        any(value.get("type") == "int" and value.get("value") == str(pulse_number) for value in array.findall("value"))
        for array in arrays
    )
    if not referenced:
        target_array = arrays[0]
        plugin_types = {number: plugin.get("value", "") for number, plugin in plugin_map(plugins).items()}
        insert_at = len(target_array.findall("value"))
        for index, value in enumerate(target_array.findall("value")):
            if plugin_types.get(int(value.get("value", "-1"))) == "systray":
                insert_at = index
                break
        target_array.insert(insert_at, ET.Element("value", {"type": "int", "value": str(pulse_number)}))

    # Arrange the right side as requested. XML stores plugins left-to-right, so
    # this tail is the reverse of the desired right-to-left visual order:
    # Clock, separator, Actions, separator, PulseAudio, tray, separator, Pager.
    plugins_by_id = plugin_map(plugins)
    target_array = arrays[0]
    current_numbers = array_numbers(target_array)

    def one_plugin_number(plugin_type: str) -> int:
        matches = [number for number, plugin in plugins_by_id.items() if plugin.get("value") == plugin_type]
        if len(matches) != 1:
            raise ValueError(f"{path}: expected one {plugin_type} plugin, found {len(matches)}")
        return matches[0]

    pager_number = one_plugin_number("pager")
    systray_number = one_plugin_number("systray")
    actions_number = one_plugin_number("actions")
    clock_number = one_plugin_number("clock")
    try:
        right_zone_start = current_numbers.index(pager_number)
    except ValueError as error:
        raise ValueError(f"{path}: workspace switcher is not on the primary panel") from error

    reusable_separators = [
        number
        for number in current_numbers[right_zone_start + 1 :]
        if plugins_by_id.get(number) is not None
        and plugins_by_id[number].get("value") == "separator"
        and not property_is_true(plugins_by_id[number], "expand")
    ][:3]
    next_number = max(plugins_by_id, default=0) + 1
    while len(reusable_separators) < 3:
        separator = ET.SubElement(
            plugins,
            "property",
            {"name": f"plugin-{next_number}", "type": "string", "value": "separator"},
        )
        plugins_by_id[next_number] = separator
        reusable_separators.append(next_number)
        next_number += 1

    for number in reusable_separators:
        separator = plugins_by_id[number]
        set_property(separator, "expand", "bool", "false")
        set_property(separator, "style", "uint", "0")

    actions = plugins_by_id[actions_number]
    set_property(actions, "appearance", "uint", "1")
    set_property(actions, "button-title", "uint", "0")

    right_zone = [
        pager_number,
        reusable_separators[0],
        systray_number,
        pulse_number,
        reusable_separators[1],
        actions_number,
        reusable_separators[2],
        clock_number,
    ]
    prefix = current_numbers[:right_zone_start]
    for value in list(target_array.findall("value")):
        target_array.remove(value)
    for number in prefix + right_zone:
        ET.SubElement(target_array, "value", {"type": "int", "value": str(number)})

    ET.indent(tree, space="  ")
    mode = path.stat().st_mode & 0o777
    with tempfile.NamedTemporaryFile("wb", dir=path.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
        tree.write(temporary, encoding="UTF-8", xml_declaration=True)
    os.chmod(temporary_path, mode)
    os.replace(temporary_path, path)
    return validate(path)


def main() -> None:
    parser = argparse.ArgumentParser(description="Configure the XFCE audio plugin and right-side panel layout")
    parser.add_argument("--check", action="store_true", help="validate without changing files")
    parser.add_argument("layouts", nargs="+", type=Path)
    args = parser.parse_args()

    for layout in args.layouts:
        plugin_name = validate(layout) if args.check else configure(layout)
        print(f"{layout}: {plugin_name} enabled")


if __name__ == "__main__":
    main()
