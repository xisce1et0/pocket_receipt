import 'package:material_ui/material_ui.dart';
import '../utils/price_analytics.dart';
import 'glass_ui.dart';

Future<Set<String>?> showMultiFilterPicker({
  required BuildContext context,
  required String title,
  required String resetLabel,
  required String showAllLabel,
  required List<String> options,
  required Set<String> initialSelectedKeys,
}) async {
  final tempSelected = Set<String>.from(initialSelectedKeys);
  final isWide = MediaQuery.of(context).size.width >= 700;

  Widget buildContent(
    BuildContext pickerContext,
    void Function(void Function()) setModalState,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: GlassColors.textPrimary,
                ),
              ),
              TextButton(
                onPressed: () {
                  setModalState(() => tempSelected.clear());
                },
                child: Text(resetLabel),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: GlassColors.divider),
        Flexible(
          child: options.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Список пока пуст',
                    style: TextStyle(color: GlassColors.textSecondary),
                  ),
                )
              : ListView(
                  shrinkWrap: true,
                  children: options.map((opt) {
                    final key = normalizeProductName(opt);
                    final isChecked = tempSelected.contains(key);
                    return InkWell(
                      onTap: () {
                        setModalState(() {
                          if (isChecked) {
                            tempSelected.remove(key);
                          } else {
                            tempSelected.add(key);
                          }
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 11,
                        ),
                        child: Row(
                          children: [
                            GlassCheckbox(
                              value: isChecked,
                              onChanged: (checked) {
                                setModalState(() {
                                  if (checked) {
                                    tempSelected.add(key);
                                  } else {
                                    tempSelected.remove(key);
                                  }
                                });
                              },
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                opt,
                                style: const TextStyle(
                                  fontSize: 15,
                                  color: GlassColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(14),
          child: SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton(
              onPressed: () => Navigator.pop(pickerContext, true),
              child: Text(
                tempSelected.isEmpty
                    ? showAllLabel
                    : 'Применить (${tempSelected.length})',
              ),
            ),
          ),
        ),
      ],
    );
  }

  final bool? confirmed;
  if (isWide) {
    confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: GlassColors.sheetBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: GlassColors.cardBorder),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
            child: StatefulBuilder(
              builder: (ctx, setModalState) =>
                  buildContent(dialogContext, setModalState),
            ),
          ),
        );
      },
    );
  } else {
    confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: GlassColors.sheetBg,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.72,
                ),
                child: buildContent(sheetContext, setModalState),
              ),
            );
          },
        );
      },
    );
  }

  if (confirmed == true) return tempSelected;
  return null;
}

String formatMultiFilterLabel({
  required String singularPrefix,
  required String pluralPrefix,
  required Set<String> selectedKeys,
  required List<String> allOptions,
}) {
  if (selectedKeys.isEmpty) return '$pluralPrefix: Все';
  if (selectedKeys.length == 1) {
    final onlyKey = selectedKeys.first;
    final found = allOptions.firstWhere(
      (o) => normalizeProductName(o) == onlyKey,
      orElse: () => onlyKey,
    );
    return '$singularPrefix: $found';
  }
  return '$pluralPrefix (${selectedKeys.length})';
}