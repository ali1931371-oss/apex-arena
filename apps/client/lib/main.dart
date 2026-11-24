import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ApexArenaApp());
}

class ApexArenaApp extends StatefulWidget {
  const ApexArenaApp({super.key});

  @override
  State<ApexArenaApp> createState() => _ApexArenaAppState();
}

class _ApexArenaAppState extends State<ApexArenaApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void _setThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'APEX ARENA',
      debugShowCheckedModeBanner: false,
      locale: const Locale('fa', 'IR'),
      supportedLocales: const [
        Locale('fa', 'IR'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: _themeMode,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: HomeScreen(
          themeMode: _themeMode,
          onThemeChanged: _setThemeMode,
        ),
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    const accent = Color(0xFFE53935);
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      surface: isDark ? const Color(0xFF15171C) : const Color(0xFFF7F7F9),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF0D0F13) : const Color(0xFFF3F4F6),
      appBarTheme: AppBarTheme(
        backgroundColor:
            isDark ? const Color(0xFF111318) : const Color(0xFFFFFFFF),
        foregroundColor: isDark ? Colors.white : const Color(0xFF17191F),
        centerTitle: false,
      ),
      cardTheme: CardTheme(
        elevation: 0,
        color: isDark ? const Color(0xFF191C22) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: isDark ? const Color(0xFF2B3039) : const Color(0xFFE5E7EB),
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.themeMode,
    required this.onThemeChanged,
    super.key,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'APEX ARENA',
          style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2),
        ),
        actions: [
          PopupMenuButton<ThemeMode>(
            tooltip: 'انتخاب پوسته',
            initialValue: themeMode,
            onSelected: onThemeChanged,
            icon: const Icon(Icons.palette_outlined),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: ThemeMode.system,
                child: Text('مطابق دستگاه'),
              ),
              PopupMenuItem(
                value: ThemeMode.light,
                child: Text('روشن'),
              ),
              PopupMenuItem(
                value: ThemeMode.dark,
                child: Text('تاریک'),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SizedBox(height: 28),
              Text(
                'میز بعدی، میدان رقابت توست',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 10),
              Text(
                'بازی مافیا به‌صورت صوتی و تصویری؛ با دوستانت اتاق بساز و وارد رقابت شو.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.8,
                    ),
              ),
              const SizedBox(height: 28),
              _ActionCard(
                icon: Icons.video_call_outlined,
                title: 'ساخت اتاق بازی',
                subtitle: 'اتاق صوتی یا تصویری خصوصی ایجاد کن',
                onTap: () => _showComingSoon(context),
              ),
              const SizedBox(height: 12),
              _ActionCard(
                icon: Icons.meeting_room_outlined,
                title: 'پیوستن به اتاق',
                subtitle: 'با کد دعوت وارد اتاق دوستانت شو',
                onTap: () => _showComingSoon(context),
              ),
              const SizedBox(height: 12),
              _ActionCard(
                icon: Icons.emoji_events_outlined,
                title: 'مسابقات APEX',
                subtitle: 'تورنمنت‌ها و رقابت‌های رسمی',
                onTap: () => _showComingSoon(context),
              ),
              const SizedBox(height: 32),
              const Center(
                child: Text(
                  'نسخه پایه در حال توسعه است',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showComingSoon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('این قابلیت در مرحله بعد فعال می‌شود.')),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 10,
        ),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(icon),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_left),
        onTap: onTap,
      ),
    );
  }
}
