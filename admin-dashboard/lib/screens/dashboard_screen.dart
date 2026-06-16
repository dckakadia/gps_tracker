import 'package:flutter/material.dart';
import 'map_screen.dart';
import 'users_screen.dart';
import 'backup_screen.dart';
import 'history_screen.dart';

class DashboardScreen extends StatefulWidget {
  final String token;
  final int initialIndex;
  DashboardScreen({required this.token, this.initialIndex = 1});

  @override
  _DashboardScreenState createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      UsersScreen(token: widget.token),
      MapScreen(token: widget.token),
      HistoryScreen(token: widget.token),
      BackupScreen(token: widget.token),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 700;

        return Scaffold(
          appBar: AppBar(
            title: Text('Admin Dashboard'),
            actions: [
              IconButton(
                icon: Icon(Icons.logout),
                tooltip: 'Logout',
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (BuildContext context) {
                      return AlertDialog(
                        title: Text('Logout'),
                        content: Text('Are you sure you want to logout?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                              Navigator.of(context).pushNamedAndRemoveUntil(
                                '/login',
                                (route) => false,
                              );
                            },
                            child: Text('Logout', style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ],
          ),
          body: SafeArea(
            child: isWide
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: _selectedIndex,
                        onDestinationSelected: (index) {
                          setState(() {
                            _selectedIndex = index;
                          });
                        },
                        labelType: NavigationRailLabelType.all,
                        destinations: [
                          NavigationRailDestination(
                            icon: Icon(Icons.people),
                            label: Text('Users'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.map),
                            label: Text('Live Map'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.history),
                            label: Text('History'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.backup),
                            label: Text('Backup'),
                          ),
                        ],
                      ),
                      Expanded(child: screens[_selectedIndex]),
                    ],
                  )
                : screens[_selectedIndex],
          ),
          bottomNavigationBar: isWide
              ? null
              : BottomNavigationBar(
                  currentIndex: _selectedIndex,
                  onTap: (index) {
                    setState(() {
                      _selectedIndex = index;
                    });
                  },
                  items: [
                    BottomNavigationBarItem(icon: Icon(Icons.people), label: 'Users'),
                    BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Live Map'),
                    BottomNavigationBarItem(icon: Icon(Icons.history), label: 'History'),
                    BottomNavigationBarItem(icon: Icon(Icons.backup), label: 'Backup'),
                  ],
                ),
        );
      },
    );
  }
}
