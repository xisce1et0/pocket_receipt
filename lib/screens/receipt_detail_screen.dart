import 'package:material_ui/material_ui.dart';
import '../widgets/glass_ui.dart';
import '../widgets/receipt_detail_content.dart';

class ReceiptDetailScreen extends StatefulWidget {
  final String receiptId;

  const ReceiptDetailScreen({
    super.key,
    required this.receiptId,
  });

  @override
  State<ReceiptDetailScreen> createState() => _ReceiptDetailScreenState();
}

class _ReceiptDetailScreenState extends State<ReceiptDetailScreen> {
  final _contentKey = GlobalKey<ReceiptDetailContentState>();

  @override
  Widget build(BuildContext context) {
    return GlassBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: const Text('Чек'),
          actions: [
            IconButton(
              onPressed: () =>
                  _contentKey.currentState?.exportCurrentToExcel(),
              icon: const Icon(Icons.table_view_outlined),
              tooltip: 'Сохранить чек в Excel',
            ),
            IconButton(
              onPressed: () => _contentKey.currentState?.editReceiptInfo(),
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Изменить магазин или дату',
            ),
            IconButton(
              onPressed: () => _contentKey.currentState?.deleteReceipt(),
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Удалить чек',
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: ReceiptDetailContent(
              key: _contentKey,
              receiptId: widget.receiptId,
              showInlineToolbar: false,
              onDeleted: () {
                if (mounted) Navigator.pop(context);
              },
            ),
          ),
        ),
      ),
    );
  }
}