import 'package:material_ui/material_ui.dart';
import '../utils/price_analytics.dart';

class MultiGroupInput extends StatelessWidget {
  final List<String> selectedGroups;
  final List<String> availableGroups;
  final TextEditingController textController;
  final ValueChanged<List<String>> onChanged;

  const MultiGroupInput({
    super.key,
    required this.selectedGroups,
    required this.availableGroups,
    required this.textController,
    required this.onChanged,
  });

  void _addGroup(String raw) {
    final clean = raw.trim();
    if (clean.isEmpty) return;
    final norm = normalizeProductName(clean);
    final alreadyExists =
        selectedGroups.any((g) => normalizeProductName(g) == norm);
    if (!alreadyExists) {
      onChanged([...selectedGroups, clean]);
    }
    textController.clear();
  }

  void _removeGroup(String group) {
    final norm = normalizeProductName(group);
    onChanged(
      selectedGroups
          .where((g) => normalizeProductName(g) != norm)
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedKeys = selectedGroups.map(normalizeProductName).toSet();
    final quickSuggestions = availableGroups
        .where((g) => !selectedKeys.contains(normalizeProductName(g)))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selectedGroups.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: selectedGroups.map((group) {
              return InputChip(
                label: Text(group),
                onDeleted: () => _removeGroup(group),
              );
            }).toList(),
          ),
          const SizedBox(height: 6),
        ],
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: textController,
                onSubmitted: _addGroup,
                decoration: const InputDecoration(
                  labelText: 'Добавить группу (можно несколько)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
              onPressed: () => _addGroup(textController.text),
              icon: const Icon(Icons.add),
              tooltip: 'Добавить группу',
            ),
          ],
        ),
        if (quickSuggestions.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: quickSuggestions.take(8).map((g) {
              return ActionChip(
                label: Text('+ $g'),
                visualDensity: VisualDensity.compact,
                onPressed: () => _addGroup(g),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }
}